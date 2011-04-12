/****************************************************************************************
 *   Copyright: Copyright (C) 2009-2010 Ulrik Mikaelsson. All rights reserved
 *
 *   License:
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 ***************************************************************************************/
module lib.connection;

private import tango.core.Exception;
private import tango.core.Signal;
private import tango.io.model.IConduit;
private import tango.net.device.Berkeley;
private import tango.net.device.Socket;
private import tango.text.convert.Format;
private import tango.time.Clock;
private import tango.util.MinMax;
private import tango.util.container.more.Heap;
private import tango.util.container.more.Stack;
private import tango.util.log.Log;

public import message = lib.message;
private import lib.protobuf;
private import lib.pumping;
private import lib.timeout;

/****************************************************************************************
 * Structure describing a still-unanswered request from BitHorde. Wraps the actual
 * request up with a timeout-time.
 ***************************************************************************************/
struct InFlightRequest {
    Connection c;
    message.RPCRequest req;
    TimeoutQueue.EventId timeout;
    void triggerTimeout(Time deadline, Time now) {
        auto req = this.req;
        c.lingerRequest(req, now); // LingerRequest destroys req, so must store local refs first.
        req.abort(message.Status.TIMEOUT);
    }
}

/****************************************************************************************
 * On Timed out requests, their request-id enters the Linger-queue for a while, in order
 * to not reuse until moderately safe from conflicts.
 ***************************************************************************************/
struct LingerId {
    Time time;
    int rpcId;
    int opCmp(LingerId other) {
        return this.time.opCmp(other.time);
    }
}

/// ditto
alias Heap!(LingerId, true) LingerIdQueue;

/****************************************************************************************
 * Small counter-helper to keep track of flow of bytes and packets.
 ***************************************************************************************/
struct Counters {
    /// Stats for one direction
    struct Stats {
        ulong packets, bytes;
        void addPacket(uint length) {
            packets += 1;
            bytes += length;
        }
    }
    Time lastSwitch;
    Stats currentIn, currentOut;
    TimeSpan prevInterval;
    Stats prevIn, prevOut;

    TimeSpan currentRequestWait, prevRequestWait;
    TimeSpan currentWorstWait = TimeSpan.zero, prevWorstWait;
    uint currentRequestCount, prevRequestCount;

    /************************************************************************************
     * add a sent packet for the current period. Won't be visible in accounting until
     * after next switch.
     ***********************************************************************************/
    void addSentPacket(uint length) {
        currentOut.addPacket(length);
    }

    /************************************************************************************
     * add a recieved packet for the current period. Won't be visible in accounting
     * until after next switch.
     ***********************************************************************************/
    void addRecvPacket(uint length) {
        currentIn.addPacket(length);
    }

    /************************************************************************************
     * submit the response-time stats for a recieved packet
     ***********************************************************************************/
    void submitRequest(TimeSpan responseTime) {
        if (responseTime > currentWorstWait)
            currentWorstWait = responseTime;
        currentRequestWait += responseTime;
        currentRequestCount += 1;
    }

    /************************************************************************************
     * Perform a switch, committing the current period
     ***********************************************************************************/
    void doSwitch(Time now) {
        prevInterval = now - lastSwitch;
        prevIn = currentIn;
        prevOut = currentOut;
        currentIn = currentOut = Stats.init;

        prevRequestCount = currentRequestCount;
        prevRequestWait = currentRequestWait;
        prevWorstWait = currentWorstWait;

        currentRequestCount = 0;
        currentRequestWait = TimeSpan.zero;
        currentWorstWait = TimeSpan.zero;

        lastSwitch = now;
    }

    /************************************************************************************
     * Render string of back-stats.
     ***********************************************************************************/
    char[] toString() {
        auto msec = max!(long)(prevInterval.millis, 1);
        return Format.convert("Recv/sec: {{{}pkts, {}KB} Sent/sec: {{{}pkts, {}KB} Requests: {{{} processed, avg. {}ms, worst {}ms}",
            (cast(double)(prevIn.packets) * 1000)/msec, cast(double)(prevIn.bytes/msec),
            (cast(double)(prevOut.packets) * 1000)/msec, cast(double)(prevOut.bytes/msec),
            prevRequestCount, (prevRequestCount>0)?prevRequestWait.millis/prevRequestCount:0,
            prevWorstWait.millis);
    }

    /************************************************************************************
     * Check if anything hit the counters last period.
     ***********************************************************************************/
    bool empty() {
        if (prevIn.packets || prevOut.packets)
            return false;
        else
            return true;
    }
}

/****************************************************************************************
 * All underlying BitHorde connections run through this class. Deals with low-level
 * serialization and request-id-mapping.
 ***************************************************************************************/
class Connection : BaseConnection
{
    alias void delegate(Connection c, message.Type t, ubyte[] msg) ProcessCallback;
    static class InvalidMessage : Exception {
        this (char[] msg="Invalid message recieved") { super(msg); }
    }
    static class InvalidResponse : InvalidMessage {
        this () { super("Invalid response recieved"); }
    }
    Signal!(Connection) onDisconnected;
    Signal!(Connection) sigWriteClear;
    ProcessCallback messageHandler;
protected:
    ByteBuffer msgbuf;
    char[] _myname, _peername;
    Logger log;
protected:

    /// inFlightRequests contains actual requests, and is the allocation-heap for IFR:s
    InFlightRequest[] inFlightRequests;
    /// Load is the number of requests currently in flight.
    uint load;
    /// TimeoutQueue for inFlightRequests
    public TimeoutQueue timeouts;
    /// Free reusable request-ids
    Stack!(ushort,100) _freeIds;
    /// Ids that can't be re-used for a while, to avoid conflicting responses
    LingerIdQueue lingerIds;
    /// Last resort, new-id allocation
    ushort nextid;

    /************************************************************************************
     * Allocate a requestId for given request
     ***********************************************************************************/
    ushort allocRequest(message.RPCRequest target) {
        if (_freeIds.size) {
            target.rpcId = _freeIds.pop();
        } else if (lingerIds.size && (lingerIds.peek.time < Clock.now)) {
            target.rpcId = lingerIds.pop.rpcId;
        } else {
            target.rpcId = nextid++;
            if (inFlightRequests.length <= target.rpcId) {
                // TODO: Why not .length = ???
                auto newInFlightRequests = new InFlightRequest[inFlightRequests.length*2];
                newInFlightRequests[0..inFlightRequests.length] = inFlightRequests;
                delete inFlightRequests;
                inFlightRequests = newInFlightRequests;

                // Timeouts is now full of broken callbacks, rebuild
                timeouts.clear();
                foreach (ref ifr; inFlightRequests[0..target.rpcId]) {
                    if (ifr.req)
                        ifr.timeout = timeouts.registerAt(ifr.timeout.at, &ifr.triggerTimeout);
                }
            }
        }
        inFlightRequests[target.rpcId].c = this;
        load += 1;
        return target.rpcId;
    }

    /************************************************************************************
     * Release the requestId for given request, after completion. Throws
     ***********************************************************************************/
    public message.RPCRequest releaseRequest(message.RPCResponse msg) {
        if (msg.rpcId >= inFlightRequests.length)
            throw new InvalidResponse;
        auto ifr = &inFlightRequests[msg.rpcId];
        auto req = ifr.req;
        if (!req)
            throw new InvalidResponse;
        counters.submitRequest(Clock.now - req.sendTime);
        msg.request = req;
        timeouts.abort(ifr.timeout);
        inFlightRequests[msg.rpcId] = InFlightRequest.init;
        load -= 1;
        if (_freeIds.unused)
            _freeIds.push(msg.rpcId);
        return req;
    }

    /************************************************************************************
     * Force-release the requestId for given request, and put it in the linger-queue;
     ***********************************************************************************/
    void lingerRequest(message.RPCRequest req, Time now) {
        counters.submitRequest(now - req.sendTime);
        LingerId li;
        li.rpcId = req.rpcId;
        li.time = now+TimeSpan.fromMillis(65536);
        lingerIds.push(li);
        inFlightRequests[req.rpcId] = InFlightRequest.init;
    }
public:
    /// Public statistics-module
    Counters counters;
    /// Signal indicating handshake is done
    Signal!(char[]) onHandshakeDone;

    /************************************************************************************
     * Create named connection, and perform HandShake
     ***********************************************************************************/
    this(Pump p, Socket s)
    {
        if (s.socket.addressFamily is AddressFamily.INET)
            s.socket.setNoDelay(true);
        super(p, s, 1024*1024);
        this._myname = myname;
        reset();
    }

    ~this() {
    }

    /************************************************************************************
     * Initialise connection members
     ***********************************************************************************/
    protected void reset() {
        this.counters.lastSwitch = Clock.now;
        this.log = Log.lookup("lib.connection");

        this._freeIds = _freeIds.init;
        this.timeouts = new TimeoutQueue;
        this.lingerIds = lingerIds.init;
        this.nextid = nextid.init;
        this._peername = _peername.init;
        this.messageHandler = &processHandShake;

        this.msgbuf = new ByteBuffer(8192);
        this.inFlightRequests = new InFlightRequest[16];
    }

    /************************************************************************************
     * Finish closing by sending DISCONNECTED notifications to all waiting callbacks.
     ***********************************************************************************/
    void onClosed() {
        foreach (ifr; inFlightRequests) {
            if (ifr.req)
                ifr.req.abort(message.Status.DISCONNECTED);
        }
        onDisconnected.call(this);
    }

    /************************************************************************************
     * Process incoming data, trying to parse out messages
     ***********************************************************************************/
    size_t onData(ubyte[] data) {
        size_t processed, msgsize;
        while ((processed < data.length) && ((msgsize = processMessage(data[processed..length])) > 0))
            processed += msgsize;
        return processed;
    }

    /************************************************************************************
     * Transmit signal the connection is now ready to send more data.
     ***********************************************************************************/
    void onWriteClear() {
        sigWriteClear.call(this);
    }

    /************************************************************************************
     * Process a single message read from previous readNewData()
     ***********************************************************************************/
    synchronized size_t processMessage(ubyte inBuf[])
    {
        auto decodeBuf = inBuf;
        message.Type type;
        size_t msglen;
        if (decode_val!(message.Type)(decodeBuf, type) && decode_val!(size_t)(decodeBuf, msglen) && (decodeBuf.length >= msglen)) {
            auto totallength = (decodeBuf.ptr - inBuf.ptr) /*length of type and length*/ + msglen;
            counters.addRecvPacket(totallength);
            try {
                assert((type & 0b0000_0111) == 0b0010, "Expected message type, but got something else");
                type >>= 3;

                messageHandler(this, type, decodeBuf[0..msglen]);
            } catch (Exception e) {
                log.error("Exception ({}:{}) in handling incoming Message: {}", e.file, e.line, e.msg);
            }
            return totallength;
        } else {
            return 0;
        }
    }

    /************************************************************************************
     * Process waiting timeouts expected to fire up until now.
     ***********************************************************************************/
    synchronized void processTimeouts(Time now) {
        timeouts.emit(now);
    }

    /************************************************************************************
     * Figure next DeadLine, which is either time to the first timeout, or TimeSpan.max
     ***********************************************************************************/
    Time nextDeadline() {
        return timeouts.nextDeadline;
    }


    /************************************************************************************
     * Measure how loaded this connection is
     ***********************************************************************************/
    uint getLoad() {
        return inFlightRequests.length;
    }

    final char[] peername() { return _peername; }
    final char[] myname() { return _myname; }
// TODO: Remove    final Address remoteAddress() { return socket ? socket.socket.remoteAddress : null; }
    char[] toString() {
        return peername;
    }

    /************************************************************************************
     * The concept of "trusted" Clients means clients allowed to perform special
     * operations, such as uploading new assets.
     ***********************************************************************************/
    bool isTrusted() {
        return true;
/+ TODO: Implement       if (closed)
            return false;
        return socket.socket.remoteAddress.addressFamily == AddressFamily.UNIX;+/
    }

    /************************************************************************************
     * Initiate handshake
     ***********************************************************************************/
    void sayHello(char[] myname) in {
        assert(messageHandler is &processHandShake);
        assert(myname.length);
    } body {
        this._myname = myname;
        scope handshake = new message.HandShake;
        handshake.name = _myname;
        handshake.protoversion = 1;
        sendMessage(handshake);
    }
package:
    /************************************************************************************
     * Send any kind of message, just serialize and push
     ***********************************************************************************/
    synchronized size_t sendMessage(message.Message m) {
        if (closed)
            throw new IOException("Connection closed");
        msgbuf.reset();
        m.encode(msgbuf);
        encode_val!(uint)(msgbuf.length, msgbuf);
        encode_val!(ushort)((m.typeId << 3) | 0b0000_0010, msgbuf);
        auto buf = msgbuf.data;
        counters.addSentPacket(buf.length);
        return write(buf);
    }

    /************************************************************************************
     * Send a request, with optional timeout, and register in corresponding idMaps.
     ***********************************************************************************/
    synchronized void sendRPCRequest(message.RPCRequest req, TimeSpan timeout) {
        auto rpcId = allocRequest(req);
        req.timeout = timeout.millis;
        req.sendTime = Clock.now;
        sendMessage(req);
        InFlightRequest* ifr = &inFlightRequests[rpcId];
        ifr.req = req;
        ifr.timeout = timeouts.registerIn(timeout, &ifr.triggerTimeout);
    }
protected:
    /************************************************************************************
     * HandShakes are the only thing Connection handles by itself. After initialization,
     * they are illegal.
     ***********************************************************************************/
    void processHandShake(Connection c, message.Type t, ubyte[] msg) {
        assert(t == message.Type.HandShake);
        scope handshake = new message.HandShake;
        handshake.decode(msg);
        _peername = handshake.name.dup;
        if (!_peername)
            throw new AssertException("Other side did not greet with handshake", __FILE__, __LINE__);
        assert(handshake.protoversion == 1);
        this.log = Log.lookup("lib.client."~peername);
        onHandshakeDone(_peername);
    }
}
