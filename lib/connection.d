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
private import tango.io.model.IConduit;
private import tango.net.device.Berkeley;
private import tango.net.device.Socket;
private import tango.time.Clock;
private import tango.util.container.more.Heap;
private import tango.util.container.more.Stack;

private import lib.protobuf;
public import message = lib.message;

/****************************************************************************************
 * Structure describing a still-unanswered request from BitHorde. Wraps the actual
 * request up with a timeout-time.
 ***************************************************************************************/
struct InFlightRequest {
    Time time;
    message.RPCRequest req;
    int opCmp(InFlightRequest other) {
        return this.time.opCmp(other.time);
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

/// Queue-types
alias Heap!(InFlightRequest*, true) TimedRequestQueue;
/// ditto
alias Heap!(LingerId, true) LingerIdQueue;

/****************************************************************************************
 * All underlying BitHorde connections run through this class. Deals with low-level
 * serialization and request-id-mapping.
 ***************************************************************************************/
class Connection
{
protected:
    Socket socket;
    ubyte[] frontbuf, backbuf, left;
    ByteBuffer msgbuf;
    char[] _myname, _peername;

protected:
    class InvalidMessage : Exception {
        this (char[] msg="Invalid message recieved") { super(msg); }
    }
    class InvalidResponse : InvalidMessage {
        this () { super("Invalid response recieved"); }
    }

    /// inFlightRequests contains actual requests, and is the allocation-heap for IFR:s
    InFlightRequest[] inFlightRequests;
    /// timeouts contains references to inFlightRequests, sorted on timeout-time. Needs care and attention
    public TimedRequestQueue timeouts;
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
                auto newInFlightRequests = new InFlightRequest[inFlightRequests.length*2];
                newInFlightRequests[0..inFlightRequests.length] = inFlightRequests;
                delete inFlightRequests;
                inFlightRequests = newInFlightRequests;

                // Timeouts is now full of broken references, rebuild
                timeouts.clear();
                foreach (ref ifr; inFlightRequests[0..target.rpcId]) {
                    if (ifr.req)
                        timeouts.push(&ifr);
                }
            }
        }
        return target.rpcId;
    }

    /************************************************************************************
     * Release the requestId for given request, after completion. Throws
     ***********************************************************************************/
    message.RPCRequest releaseRequest(message.RPCResponse msg) {
        if (msg.rpcId >= inFlightRequests.length)
            throw new InvalidResponse;
        auto ifr = &inFlightRequests[msg.rpcId];
        auto req = ifr.req;
        if (!req)
            throw new InvalidResponse;
        msg.request = req;
        timeouts.remove(ifr);
        inFlightRequests[msg.rpcId] = InFlightRequest.init;
        if (_freeIds.unused)
            _freeIds.push(msg.rpcId);
        return req;
    }

    /************************************************************************************
     * Force-release the requestId for given request, and put it in the linger-queue;
     ***********************************************************************************/
    void lingerRequest(message.RPCRequest req) {
        LingerId li;
        li.rpcId = req.rpcId;
        li.time = Clock.now+TimeSpan.fromMillis(65536);
        lingerIds.push(li);
        inFlightRequests[req.rpcId] = InFlightRequest.init;
    }
public:
    /************************************************************************************
     * Create named connection, and perform HandShake
     ***********************************************************************************/
    this(char[] myname)
    {
        this._myname = myname;
    }

    ~this() {
    }

    /************************************************************************************
     * Initialise connection members
     ***********************************************************************************/
    protected void reset() {
        this._freeIds = _freeIds.init;
        this.timeouts = timeouts.init;
        this.lingerIds = lingerIds.init;
        this.nextid = nextid.init;
        this._peername = _peername.init;

        this.frontbuf = new ubyte[8192];
        this.backbuf = new ubyte[8192];
        this.left = [];
        this.msgbuf = new ByteBuffer(8192);
        this.inFlightRequests = new InFlightRequest[16];
    }

    /************************************************************************************
     * Bind open Socket to this connection and performs handshake
     ***********************************************************************************/
    protected void handshake(Socket s) {
        reset();

        this.socket = s;
        if (s.socket.addressFamily is AddressFamily.INET)
            this.socket.socket.setNoDelay(true);

        sayHello();
        expectHello();
    }

    final bool closed() { return (socket is null); }

    /************************************************************************************
     * Trigger closing of the connection
     ***********************************************************************************/
    void close() {
        if (closed)
            return;
        socket.shutdown();
        socket.close();
        onClose();
    }

    /************************************************************************************
     * Send DISCONNECTED notifications to all waiting callbacks.
     ***********************************************************************************/
    protected void onClose() {
        socket = null;
        foreach (ifr; inFlightRequests) {
            if (ifr.req)
                ifr.req.abort(message.Status.DISCONNECTED);
        }
    }

    /************************************************************************************
     * Read any new data from underlying socket. Blocks until data is available.
     ***********************************************************************************/
    synchronized bool readNewData() {
        if (closed)
            throw new IOException("Connection closed");
        swapBufs();
        int read = socket.read(frontbuf[left.length..length]);
        if (read > 0) {
            left = frontbuf[0..left.length+read];
            return true;
        } else
            return false;
    }

    /************************************************************************************
     * Process a single message read from previous readNewData()
     ***********************************************************************************/
    synchronized bool processMessage()
    {
        auto buf = left;
        left = decodeMessage(buf);
        return buf != left;
    }

    /************************************************************************************
     * Process waiting timeouts expected to fire up until now.
     ***********************************************************************************/
    synchronized void processTimeouts() {
        while (timeouts.size && (Clock.now > timeouts.peek.time)) {
            auto req = timeouts.pop.req;
            lingerRequest(req);
            req.abort(message.Status.TIMEOUT);
        }
    }

    /************************************************************************************
     * Figure next TimeOut, which is either time to the first timeout, or TimeSpan.max
     ***********************************************************************************/
    TimeSpan nextTimeOut() {
        return timeouts.size ? (timeouts.peek.time-Clock.now) : TimeSpan.max;
    }

    final char[] peername() { return _peername; }
    final char[] myname() { return _myname; }
    final Address remoteAddress() { return socket ? socket.socket.remoteAddress : null; }
    char[] toString() {
        return peername;
    }

    /************************************************************************************
     * The concept of "trusted" Clients means clients allowed to perform special
     * operations, such as uploading new assets.
     ***********************************************************************************/
    bool isTrusted() {
        if (closed)
            return false;
        return socket.socket.remoteAddress.addressFamily == AddressFamily.UNIX;
    }

    /************************************************************************************
     * Process a single Message
     ***********************************************************************************/
    void process(message.Type type, ubyte[] msg) {
        with (message) switch (type) {
        case Type.HandShake: processHandShake(msg); break;
        case Type.OpenRequest: processOpenRequest(msg); break;
        case Type.UploadRequest: processUploadRequest(msg); break;
        case Type.OpenResponse: processOpenResponse(msg); break;
        case Type.Close: processClose(msg); break;
        case Type.ReadRequest: processReadRequest(msg); break;
        case Type.ReadResponse: processReadResponse(msg); break;
        case Type.DataSegment: processDataSegment(msg); break;
        case Type.MetaDataRequest: processMetaDataRequest(msg); break;
        case Type.MetaDataResponse: processMetaDataResponse(msg); break;
        default: throw new InvalidMessage;
        }
    }
private:
    /// Initiate HandShake
    void sayHello() {
        scope handshake = new message.HandShake;
        handshake.name = _myname;
        handshake.protoversion = 1;
        sendMessage(handshake);
    }
    /// Complete HandShake
    void expectHello() {
        while (!processMessage()) {
            readNewData();
        }
        if (!_peername)
            throw new AssertException("Other side did not greet with handshake", __FILE__, __LINE__);
    }

    /************************************************************************************
     * The connection works on a double-buffered system. swapBufs swaps the buffers, and
     * copies any remainder from old frontbuf to new frontbuf.
     ***********************************************************************************/
    void swapBufs() {
        auto remainder = left.length;
        if ((remainder * 2) > backbuf.length) { // When old frontBuf was more than half-full
            auto newsize = remainder * 2;       // Alloc new backbuf
            delete backbuf;                     // TODO: Implement some upper-limit
            backbuf = new ubyte[newsize];
        }
        backbuf[0..remainder] = left; // Copy remainder to backbuf
        left = frontbuf;              // Remember current frontbuf
        frontbuf = backbuf;           // Switch new frontbuf to current backbuf
        backbuf = left;               // And new backbuf is our current frontbuf
        left = frontbuf[0..remainder];
    }

    /************************************************************************************
     * Attempt to decode and process a single message from a buffer
     ***********************************************************************************/
    ubyte[] decodeMessage(ubyte[] data)
    {
        auto buf = data;
        auto type = decode_val!(message.Type)(buf);
        if (buf == data) {
            return data;
        } else {
            assert((type & 0b0000_0111) == 0b0010, "Expected message type, but got something else");
            type >>= 3;
        }
        uint msglen = decode_val!(uint)(buf);
        if (buf == data || buf.length < msglen) {
            return data; // Not enough data in buffer
        } else {
            auto msg = buf[0..msglen];
            process(type, msg);
            return buf[msglen..length];
        }
    }
package:
    /************************************************************************************
     * Send any kind of message, just serialize and push
     ***********************************************************************************/
    synchronized void sendMessage(message.Message m) {
        if (closed)
            throw new IOException("Connection closed");
        msgbuf.reset();
        m.encode(msgbuf);
        encode_val!(uint)(msgbuf.length, msgbuf);
        encode_val!(ushort)((m.typeId << 3) | 0b0000_0010, msgbuf);
        socket.write(msgbuf.data);
    }

    /************************************************************************************
     * Send a request, with optional timeout, and register in corresponding idMaps.
     ***********************************************************************************/
    synchronized void sendRequest(message.RPCRequest req) {
        // TODO: Randomize?
        sendRequest(req, TimeSpan.fromMillis(4000));
    }
    /// ditto
    synchronized void sendRequest(message.RPCRequest req, TimeSpan timeout) {
        auto rpcId = allocRequest(req);
        req.timeout = timeout.millis;
        sendMessage(req);
        auto ifr = &inFlightRequests[rpcId];
        ifr.req = req;
        ifr.time = Clock.now + timeout;
        timeouts.push(ifr);
    }
protected:
    /************************************************************************************
     * HandShakes are the only thing Connection handles by itself. After initialization,
     * they are illegal.
     ***********************************************************************************/
    void processHandShake(ubyte[] msg) {
        if (_peername)
            throw new AssertException("HandShake recieved after initialization", __FILE__, __LINE__);
        scope handshake = new message.HandShake;
        handshake.decode(msg);
        _peername = handshake.name.dup;
        assert(handshake.protoversion == 1);
    }
    abstract void processOpenRequest(ubyte[]);
    abstract void processUploadRequest(ubyte[]);
    abstract void processOpenResponse(ubyte[]);
    abstract void processClose(ubyte[]);
    abstract void processReadRequest(ubyte[]);
    abstract void processReadResponse(ubyte[]);
    abstract void processDataSegment(ubyte[]);
    abstract void processMetaDataRequest(ubyte[]);
    abstract void processMetaDataResponse(ubyte[]);
}
