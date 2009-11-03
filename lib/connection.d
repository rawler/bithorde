module lib.connection;

private import tango.io.Stdout;
private import tango.net.Socket;
private import tango.net.SocketConduit;
private import tango.util.container.more.Stack;

private import lib.protobuf;
public import message = lib.message;

class Connection
{
protected:
    SocketConduit socket;
    ubyte[] frontbuf, backbuf;
    uint remainder;
    ByteBuffer msgbuf;
    char[] _myname, _peername;

protected: // TODO: This logic should really be moved into lib/Client layer soon.
    message.RPCRequest[] inFlightRequests;
    Stack!(ushort,100) _freeIds;
    ushort nextid;
    void allocRequest(message.RPCRequest target) {
        if (_freeIds.size)
            target.rpcId = _freeIds.pop();
        else {
            target.rpcId = nextid++;
            if (inFlightRequests.length <= target.rpcId) {
                auto newInFlightRequests = new message.RPCRequest[inFlightRequests.length*2];
                newInFlightRequests[0..inFlightRequests.length] = inFlightRequests;
                delete inFlightRequests;
                inFlightRequests = newInFlightRequests;
            }
        }
        inFlightRequests[target.rpcId] = target;
    }
    message.RPCRequest releaseRequest(message.RPCResponse msg) {
        auto req = inFlightRequests[msg.rpcId];
        msg.request = req;
        inFlightRequests[msg.rpcId] = null;
        if (_freeIds.unused)
            _freeIds.push(msg.rpcId);
        return req;
    }
public:
    this(SocketConduit s, char[] myname)
    {
        this.socket = s;
        this.frontbuf = new ubyte[8192]; // TODO: Handle overflow
        this.backbuf = new ubyte[8192];
        this.remainder = 0;
        this.msgbuf = new ByteBuffer(8192);
        if (s.socket.addressFamily is AddressFamily.INET)
            this.socket.socket.setNoDelay(true);
        this.inFlightRequests = new message.RPCRequest[16];
        this._myname = myname;
        sayHello();
        expectHello();
    }
    ~this()
    {
        socket.close();
    }

    synchronized bool read()
    {
        int read = socket.read(frontbuf[remainder..length]);
        if (read > 0) {
            ubyte[] buf, left = frontbuf[0..remainder + read];
            while (buf != left && left.length > 3) {
                buf = left;
                left = decodeMessage(buf);
            }
            swapBufs(left);
            return true;
        } else {
            return false;
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
        int read = socket.read(frontbuf);
        auto left = frontbuf[0..read];
        auto id = decode_val!(ubyte)(left);
        assert(id == (message.Type.HandShake<<3 | 0b0010));
        auto length = decode_val!(ushort)(left);
        assert(length > 0);
        assert(left.length >= length);
        scope auto handshake = new message.HandShake;
        handshake.decode(left[0..length]);
        _peername = handshake.name.dup;
        assert(handshake.protoversion == 1);
        swapBufs(left[length..left.length]);
    }
    void swapBufs(ubyte[] left) {
        remainder = left.length;
        if ((remainder * 2) > backbuf.length) { // Alloc new backbuf
            auto newsize = remainder * 2;       // TODO: Implement some upper-limit
            delete backbuf;
            backbuf = new ubyte[newsize];
        }
        backbuf[0..remainder] = left; // Copy remainder to backbuf
        left = frontbuf;              // Remember current frontbuf
        frontbuf = backbuf;           // Switch new frontbuf to current backbuf
        backbuf = left;               // And new backbuf is our current frontbuf
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
            case Type.HandShake:
                Stderr("Error: HandShake recieved after initialization").newline;
                break;
            case Type.OpenRequest: processOpenRequest(msg); break;
            case Type.UploadRequest: processUploadRequest(msg); break;
            case Type.OpenResponse: processOpenResponse(msg); break;
            case Type.Close: processClose(msg); break;
            case Type.ReadRequest: processReadRequest(msg); break;
            case Type.ReadResponse: processReadResponse(msg); break;
            case Type.DataSegment: processDataSegment(msg); break;
            case Type.MetaDataRequest: processMetaDataRequest(msg); break;
            case Type.MetaDataResponse: processMetaDataResponse(msg); break;
            default:
                Stderr.format("Unknown message type; {}", type).newline;
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
        allocRequest(req);
        sendMessage(req);
    }
protected:
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
