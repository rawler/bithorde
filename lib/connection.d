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

private:
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
    void releaseRequest(message.RPCResponse msg) {
        msg.request = inFlightRequests[msg.rpcId];
        inFlightRequests[msg.rpcId] = null;
        if (_freeIds.unused)
            return _freeIds.push(msg.rpcId);
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
private:
    void sayHello() {
        auto buf = new ByteBuffer;
        enc_wt_ld!(char[])(_myname, buf);
        socket.write(buf.data);
    }
    void expectHello() {
        int read = socket.read(frontbuf);
        auto left = frontbuf[0..read];
        auto id = dec_wt_ld!(char[])(left);
        _peername = id.dup;
        swapBufs(left);
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
        auto type = dec_varint!(message.Type)(buf);
        if (buf == data) {
            return data;
        } else {
            assert((type & 0b0000_0111) == 0b0010);
            type >>= 3;
        }
        uint msglen = dec_varint!(uint)(buf);
        if (buf == data || buf.length < msglen) {
            return data; // Not enough data in buffer
        } else {
            with (message) { switch (type) {
            case Type.OpenRequest:
                scope auto msg = new OpenRequest;
                msg.decode(buf[0..msglen]);
                process(msg);
                break;
            case Type.OpenResponse:
                scope auto msg = new OpenResponse;
                msg.decode(buf[0..msglen]);
                releaseRequest(msg);
                process(msg);
                break;
            case Type.Close:
                scope auto msg = new Close;
                msg.decode(buf[0..msglen]);
                process(msg);
                break;
            case Type.ReadRequest:
                scope auto msg = new ReadRequest;
                msg.decode(buf[0..msglen]);
                process(msg);
                break;
            case Type.ReadResponse:
                scope auto msg = new ReadResponse;
                msg.decode(buf[0..msglen]);
                releaseRequest(msg);
                process(msg);
                break;
            default:
                Stderr.format("Unknown message type; {}", type).newline;
            } }
            return buf[msglen..length];
        }
    }
protected:
    synchronized void sendMessage(message.Message m) {
        msgbuf.reset();
        m.encode(msgbuf);
        enc_varint!(uint)(msgbuf.length, msgbuf);
        enc_varint!(ushort)((m.typeId << 3) | 0b0000_0010, msgbuf);
        socket.write(msgbuf.data);
    }
    synchronized void sendRequest(message.RPCRequest req) {
        allocRequest(req);
        sendMessage(req);
    }
    abstract void process(message.OpenRequest);
    abstract void process(message.OpenResponse);
    abstract void process(message.Close);
    abstract void process(message.ReadRequest);
    abstract void process(message.ReadResponse);
}
