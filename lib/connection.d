module lib.connection;

private import tango.io.Stdout;
private import tango.net.Socket;
private import tango.net.SocketConduit;
private import tango.util.container.more.Stack;

private import lib.protobuf;
public import lib.message;

class Connection
{
protected:
    SocketConduit socket;
    ubyte[] frontbuf, backbuf;
    uint remainder;
    ByteBuffer msgbuf;
    BitHordeMessage[100] requests;
    Stack!(ushort,100) availableRequests;
    char[] _myname, _peername;
public:
    this(SocketConduit s, char[] myname)
    {
        this.socket = s;
        this.frontbuf = new ubyte[8192]; // TODO: Handle overflow
        this.backbuf = new ubyte[8192];
        this.remainder = 0;
        this.msgbuf = new ByteBuffer(8192);
        for (auto i = 0; i < 100; i++) { // FIXME: Alloc smarter
            auto msg = new BitHordeMessage;
            msg.id = i;
            requests[i] = msg;
            availableRequests.push(i);
        }
        if (s.socket.addressFamily is AddressFamily.INET)
            this.socket.socket.setNoDelay(true);
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
        uint msglen = dec_varint!(uint)(buf);
        if (buf == data || buf.length < msglen) {
            return data; // Not enough data in buffer
        } else {
            scope auto msg = new BitHordeMessage();
            msg.decode(buf[0..msglen]);
            if (msg.isResponse) {
                auto req = requests[msg.id];
                scope (exit) availableRequests.push(req.id);
                processResponse(req, msg);
            } else {
                processRequest(msg);
            }
            return buf[msglen..length];
        }
    }

protected:
    synchronized BitHordeMessage allocRequest(BitHordeMessage.Type t)
    {
        auto msgid = availableRequests.pop();
        auto msg = requests[msgid];
        msg.type = t;
        return msg;
    }
    synchronized void sendMessage(BitHordeMessage m)
    {
        msgbuf.reset();
        m.encode(msgbuf);
        enc_varint!(uint)(msgbuf.length, msgbuf);
        socket.write(msgbuf.data);
    }
    abstract void processResponse(BitHordeMessage req, BitHordeMessage response);
    abstract void processRequest(BitHordeMessage req);
}
