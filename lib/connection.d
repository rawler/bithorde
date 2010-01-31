module lib.connection;

private import tango.core.Exception;
private import tango.io.selector.Selector;
private import tango.net.device.Berkeley;
private import tango.net.device.Socket;
private import tango.time.Clock;
private import tango.util.container.more.Heap;
private import tango.util.container.more.Stack;

private import lib.protobuf;
public import message = lib.message;

struct InFlightRequest {
    Time time;
    message.RPCRequest req;
    int opCmp(InFlightRequest other) {
        return this.time.opCmp(other.time);
    }
}
struct LingerId {
    Time time;
    int rpcId;
    int opCmp(LingerId other) {
        return this.time.opCmp(other.time);
    }
}
alias Heap!(InFlightRequest*, true) TimedRequestQueue;
alias Heap!(LingerId, true) LingerIdQueue;

class Connection
{
protected:
    Socket socket;
    ubyte[] frontbuf, backbuf, left;
    ByteBuffer msgbuf;
    char[] _myname, _peername;

protected:
    // inFlightRequests contains actual requests, and is the allocation-heap for IFR:s
    InFlightRequest[] inFlightRequests;
    // timeouts contains references to inFlightRequests, sorted on timeout-time. Needs care and attention
    public TimedRequestQueue timeouts;
    // Free reusable ids
    Stack!(ushort,100) _freeIds;
    // Ids that can't be re-used for a while, to avoid conflicting responses
    LingerIdQueue lingerIds;
    // Last resort, new-id allocation
    ushort nextid;

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
    message.RPCRequest releaseRequest(message.RPCResponse msg) {
        if (msg.rpcId >= inFlightRequests.length)
            return null;
        auto ifr = &inFlightRequests[msg.rpcId];
        auto req = ifr.req;
        if (!req)
            return null;
        msg.request = req;
        timeouts.remove(ifr);
        inFlightRequests[msg.rpcId] = InFlightRequest.init;
        if (_freeIds.unused)
            _freeIds.push(msg.rpcId);
        return req;
    }
    void lingerRequest(message.RPCRequest req) {
        LingerId li;
        li.rpcId = req.rpcId;
        li.time = Clock.now+TimeSpan.fromMillis(65536);
        lingerIds.push(li);
        inFlightRequests[req.rpcId] = InFlightRequest.init;
    }
public:
    this(Socket s, char[] myname)
    {
        this.socket = s;
        this.frontbuf = new ubyte[8192]; // TODO: Handle overflow
        this.backbuf = new ubyte[8192];
        this.left = [];
        this.msgbuf = new ByteBuffer(8192);
        if (s.socket.addressFamily is AddressFamily.INET)
            this.socket.socket.setNoDelay(true);
        this.inFlightRequests = new InFlightRequest[16];
        this._myname = myname;
        sayHello();
        expectHello();
    }

    ~this() {
        close();
    }

    bool closed;
    void close(bool reallyClose = true) {
        if (closed)
            return;
        closed = true;
        if (reallyClose && socket)
            socket.close();
        foreach (ifr; inFlightRequests) {
            if (ifr.req)
                ifr.req.abort(message.Status.DISCONNECTED);
        }
    }

    synchronized bool readNewData() {
        swapBufs();
        int read = socket.read(frontbuf[left.length..length]);
        if (read > 0) {
            left = frontbuf[0..left.length+read];
            return true;
        } else
            return false;
    }

    synchronized bool processMessage()
    {
        auto buf = left;
        left = decodeMessage(buf);
        return buf != left;
    }

    synchronized void processTimeouts() {
        while (timeouts.size && (Clock.now > timeouts.peek.time)) {
            auto req = timeouts.pop.req;
            lingerRequest(req);
            req.abort(message.Status.TIMEOUT);
        }
    }

    void run() {
        auto selector = new Selector;
        selector.open(1,1);
        selector.register(socket, Event.Read|Event.Error);

        while (!closed) {
            auto timeout = timeouts.size ? (timeouts.peek.time-Clock.now) : TimeSpan.max;
            if (selector.select(timeout) > 0) {
                foreach (key; selector.selectedSet()) {
                    assert(key.conduit is socket);
                    if (key.isReadable) {
                        auto read = readNewData;
                        assert(read, "Selector indicated data, but failed reading");
                        while (processMessage()) {}
                    } else if (key.isError) {
                        close(false);
                    }
                }
            }
            processTimeouts();
        }
    }

    final char[] peername() { return _peername; }
    final char[] myname() { return _myname; }
    char[] toString() {
        return peername;
    }
    bool isTrusted() {
        return socket.socket.remoteAddress.addressFamily == AddressFamily.UNIX;
    }
private:
    void sayHello() {
        scope auto handshake = new message.HandShake;
        handshake.name = _myname;
        handshake.protoversion = 1;
        sendMessage(handshake);
    }
    void expectHello() {
        while (!processMessage()) {
            readNewData();
        }
        if (!_peername)
            throw new AssertException("Other side did not greet with handshake", __FILE__, __LINE__);
    }
    void swapBufs() {
        auto remainder = left.length;
        if ((remainder * 2) > backbuf.length) { // Alloc new backbuf
            auto newsize = remainder * 2;       // TODO: Implement some upper-limit
            delete backbuf;
            backbuf = new ubyte[newsize];
        }
        backbuf[0..remainder] = left; // Copy remainder to backbuf
        left = frontbuf;              // Remember current frontbuf
        frontbuf = backbuf;           // Switch new frontbuf to current backbuf
        backbuf = left;               // And new backbuf is our current frontbuf
        left = frontbuf[0..remainder];
    }
    ubyte[] decodeMessage(ubyte[] data)
    {
        auto buf = data;
        auto type = decode_val!(message.Type)(buf);
        if (buf == data) {
            return data;
        } else {
            assert((type & 0b0000_0111) == 0b0010);
            type >>= 3;
        }
        uint msglen = decode_val!(uint)(buf);
        if (buf == data || buf.length < msglen) {
            return data; // Not enough data in buffer
        } else {
            auto msg = buf[0..msglen];
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
            }
            return buf[msglen..length];
        }
    }
package:
    synchronized void sendMessage(message.Message m) {
        msgbuf.reset();
        m.encode(msgbuf);
        encode_val!(uint)(msgbuf.length, msgbuf);
        encode_val!(ushort)((m.typeId << 3) | 0b0000_0010, msgbuf);
        socket.write(msgbuf.data);
    }
    synchronized void sendRequest(message.RPCRequest req) {
        // TODO: Randomize?
        sendRequest(req, TimeSpan.fromMillis(500));
    }
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
    void processHandShake(ubyte[] msg) {
        if (_peername)
            throw new AssertException("HandShake recieved after initialization", __FILE__, __LINE__);
        scope auto handshake = new message.HandShake;
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
