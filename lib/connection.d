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
private import tango.math.random.Random;
private import tango.net.device.Berkeley;
private import tango.net.device.Socket;
private import tango.text.convert.Format;
private import tango.util.cipher.AES;
private import tango.util.cipher.Cipher;
private import tango.util.cipher.RC4;
private import tango.time.Clock;
private import tango.util.container.more.Heap;
private import tango.util.container.more.Stack;
private import tango.util.Convert;
private import tango.util.digest.Sha256;
private import tango.util.log.Log;
private import tango.util.MinMax;

private import lib.cipher.counter;
private import lib.cipher.hmac;
private import lib.cipher.xor;
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

class AuthenticationFailure : Exception {
    this(char[] msg) { super(msg); }
}

/****************************************************************************************
 * All underlying BitHorde connections run through this class. Deals with low-level
 * serialization and request-id-mapping.
 ***************************************************************************************/
class Connection : FilteredSocket
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

    /// Signal indicating other side has initiated handshake
    Signal!(Connection) onPeerPresented;

    /// Signal indicating handshake is done
    Signal!(Connection) onAuthenticated;

    private ProcessCallback _messageHandler;
    ProcessCallback messageHandler(ProcessCallback h) { return _messageHandler = h; }

    ubyte protoversion = 2;

    /// Interval of silence before sending Ping.
    TimeSpan heartbeatInterval;
protected:
    ByteBuffer msgbuf;
    char[] _myname, _peername;
    Logger log;

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

    /// Id for current timeoutEvent
    TimeoutQueue.EventId pingTimeout;

    /// Key used for auth and encryption on this connection.
    ubyte[] _sharedKey;
    public ubyte[] sharedKey() { return _sharedKey; }

    /// Ciphers used for sending to/recieving from connection.
    message.CipherType _sendCipher, _recvCipher = message.CipherType.CLEARTEXT;
    public message.CipherType sendCipher() { return _sendCipher; }
    public message.CipherType recvCipher() { return _recvCipher; }

    /// The challenge we used for authentication
    ubyte[] _sentChallenge;

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
                inFlightRequests.length = inFlightRequests.length*2;

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

    /************************************************************************************
     * Create named connection, and perform HandShake
     ***********************************************************************************/
    this(Pump p, Socket s) {
        if (s.socket.addressFamily is AddressFamily.INET)
            s.socket.setNoDelay(true);
        this._myname = myname;
        reset();
        super(p, s, 1024*1024);
    }

    ~this() {
    }

    /************************************************************************************
     * Initialise connection members
     ***********************************************************************************/
    private void reset() {
        this.counters.lastSwitch = Clock.now;
        this.log = Log.lookup("lib.connection");

        this._freeIds = _freeIds.init;
        this.timeouts = new TimeoutQueue;
        this.lingerIds = lingerIds.init;
        this.nextid = nextid.init;
        this._peername = _peername.init;
        this._messageHandler = &processHandShake;

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
        resetPingTimeout();
        return processed;
    }


    /************************************************************************************
     * Resets pingTimeout, and sets a new if heartbeatInterval is set.
     ***********************************************************************************/
    void resetPingTimeout() {
        if (pingTimeout != pingTimeout.init)
            timeouts.abort(pingTimeout);

        if ((protoversion >= 2) && (heartbeatInterval != heartbeatInterval.zero))
            pingTimeout = timeouts.registerIn(heartbeatInterval, &sendPing);
        else
            pingTimeout = pingTimeout.init;
    }

    /************************************************************************************
     * Resets pingTimeout, and sets a new if heartbeatInterval is set.
     ***********************************************************************************/
    void sendPing(Time deadline, Time now) {
        auto ping = new message.Ping;
        auto timeout = (heartbeatInterval / 3);
        ping.timeout = timeout.millis;
        sendMessage(ping);
        pingTimeout = timeouts.registerIn(timeout, &onNoPingResponse);
    }

    void onNoPingResponse(Time deadline, Time now) {
        log.trace("No activity, closing");
        close();
    }

    /************************************************************************************
     * Transmit signal the connection is now ready to send more data.
     ***********************************************************************************/
    void onWriteClear() {
        sigWriteClear.call(this);
    }

    /************************************************************************************
     * Process a single message read from onData()
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

                _messageHandler(this, type, decodeBuf[0..msglen]);
            } catch (Exception e) {
                char[65536] msg;
                size_t used = 0;
                void _write(char[] buf) {
                    auto newFill = used + buf.length;
                    if (newFill <= msg.length) {
                        msg[used..newFill] = buf;
                        used = newFill;
                    }
                }
                e.writeOut(&_write);
                log.error("Exception ({}:{}) in handling incoming Message: {}", e.file, e.line, msg[0..used]);
            }
            return totallength;
        } else {
            return 0;
        }
    }

    /************************************************************************************
     * Process waiting timeouts expected to fire up until now.
     ***********************************************************************************/
    void processTimeouts(Time now) {
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
        return conduit.socket.remoteAddress.addressFamily == AddressFamily.UNIX;
    }

    /************************************************************************************
     * Initiate handshake
     ***********************************************************************************/
    void sayHello(char[] myname, message.CipherType cipher, ubyte[] sharedKey) in {
        // TODO: What about CLEARTEXT && sharedKey and the other way around?
        assert(_messageHandler is &processHandShake);
        assert(myname.length, "empty/unspecified name");
        assert(protoversion >= 2 || !(sharedKey || cipher), "sharedKey is only supported for protoversion >= 2");
    } body {
        this._myname = myname;
        scope handshake = new message.HandShake;
        handshake.name = _myname;
        handshake.protoversion = protoversion;

        _sharedKey = sharedKey;
        if (sharedKey) {
            _sentChallenge = new ubyte[16];
            rand.randomizeUniform!(ubyte[], false)(_sentChallenge);
            handshake.challenge = this._sentChallenge;
        } else {
            _sentChallenge = null;
        }

        _sendCipher = cipher;

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
    Cipher newCipherFromIV(message.CipherType type, ubyte[] cipheriv) in {
        assert(_sharedKey);
        assert(type != message.CipherType.CLEARTEXT);
    } body {
        switch (type) {
            case message.CipherType.XOR:
                auto sessionKey = HMAC!(Sha256)(_sharedKey, cipheriv);
                return new XORCipher(sessionKey);
                break;
            case message.CipherType.RC4:
                auto sessionKey = HMAC!(Sha256)(_sharedKey, cipheriv);
                auto cipher = new RC4(true, sessionKey);
                ubyte[1536] junk;
                cipher.update(junk, junk); // Best practice for RC4 is to discard first 6 * 256-bytes of keyStream
                return cipher;
            case message.CipherType.AES_CTR:
                auto aesKey = _sharedKey.dup;
                aesKey.length = 16;
                return new CounterCipher!(AES)(aesKey, cipheriv);
            default:
                throw new AuthenticationFailure("Unexpected Cipher requested in newCipherFromIV: " ~ to!(char[])(type));
        }
    }

    /************************************************************************************
     * Create and send handShakeConfirmation
     ***********************************************************************************/
    void confirmChallenge(message.HandShake handshake) in {
        assert(_myname && _sharedKey);
    } body {
        scope msg = new message.HandShakeConfirm;
        auto confirmSource = handshake.challenge;

        Cipher cipher = null;
        if (_sendCipher != message.CipherType.CLEARTEXT) {
            ubyte[] cipheriv;
            switch (_sendCipher) {
                case message.CipherType.XOR:
                case message.CipherType.RC4:
                    cipheriv = new ubyte[256/8];
                    break;
                case message.CipherType.AES_CTR:
                    cipheriv = new ubyte[16];
                    break;
                default:
                    throw new AuthenticationFailure("Unexpected sendCipher requested: " ~ to!(char[])(_sendCipher));
            }
            rand.randomizeUniform!(ubyte[], false)(cipheriv);

            msg.cipher = _sendCipher;
            msg.cipheriv = cipheriv;

            confirmSource ~= cast(ubyte)_sendCipher ~ cipheriv;
            cipher = newCipherFromIV(_sendCipher, cipheriv);
        }
        msg.authentication = HMAC!(Sha256)(_sharedKey, confirmSource);

        sendMessage(msg);

        if (cipher)
            writeFilter = &cipher.update;
    }

    void handleAuthFail(AuthenticationFailure e) {
        log.warn("Authentication failure: {}", e.msg);
        close();
    }

    /************************************************************************************
     * HandShakes are the only thing Connection handles by itself. After initialization,
     * they are illegal.
     ***********************************************************************************/
    void processHandShake(Connection c, message.Type t, ubyte[] msg) {
        if (t != message.Type.HandShake)
            throw new AssertException("Unexpected message Type: " ~ to!(char[])(t), __FILE__, __LINE__);
        scope handshake = new message.HandShake;
        handshake.decode(msg);

        if (!handshake.name)
            throw new AssertException("Other side did not greet with handshake", __FILE__, __LINE__);
        _peername = handshake.name.dup;
        this.log = Log.lookup("lib.client."~_peername);

        if (!handshake.protoversionIsSet)
            throw new AssertException("Other side did not include protocol version in handshake.", __FILE__, __LINE__);
        protoversion = handshake.protoversion;

        try {
            onPeerPresented(this);

            if (handshake.challenge) {
                if (_sharedKey) {
                    confirmChallenge(handshake);
                    _messageHandler = &processHandShakeConfirmation;
                } else {
                    throw new AuthenticationFailure(_peername ~ " required unknown authentication.");
                }
            }
            if (!_sharedKey) // No auth required
                onAuthenticated(this);
        } catch (AuthenticationFailure e) {
            handleAuthFail(e);
        }
    }

    /// Ditto
    void processHandShakeConfirmation(Connection c, message.Type t, ubyte[] msg) in {
        assert(_sharedKey);
        assert(_sentChallenge);
    } body {
        if (t != message.Type.HandShakeConfirm)
            throw new AuthenticationFailure(_peername ~ " did not send HandShakeConfirm, but: " ~ to!(char[])(t));
        scope confirmation = new message.HandShakeConfirm;
        confirmation.decode(msg);

        auto confirmSource = _sentChallenge;
        if (confirmation.cipherIsSet)
            confirmSource ~= cast(ubyte)confirmation.cipher;
        if (confirmation.cipherivIsSet)
            confirmSource ~= confirmation.cipheriv;
        if (confirmation.authentication != HMAC!(Sha256)(_sharedKey, confirmSource))
            throw new AuthenticationFailure("Attempted authentication failed for " ~ _peername);

        _recvCipher = confirmation.cipher;
        // Peer is now validated.
        if (_recvCipher != message.CipherType.CLEARTEXT) {
            if (!confirmation.cipheriv.length)
                throw new AuthenticationFailure("Remote side specified encryption without IV");
            readFilter = &newCipherFromIV(_recvCipher, confirmation.cipheriv).update;
        }

        onAuthenticated(this);
    }
}
