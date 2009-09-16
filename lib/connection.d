module lib.connection;

private import tango.io.Stdout;
private import tango.net.SocketConduit;

private import lib.protobuf;
public import lib.message;

class Connection
{
private:
    SocketConduit socket;
    ubyte[] frontbuf, backbuf;
    uint remainder;
    ByteBuffer msgbuf, szbuf;
public:
    this(SocketConduit s)
    {
        this.socket = s;
        this.frontbuf = new ubyte[4096];
        this.backbuf = new ubyte[4096];
        this.szbuf = new ByteBuffer(16);
        this.msgbuf = new ByteBuffer(4096);
    }

    bool read()
    {
        int read = socket.read(frontbuf[remainder..length]);
        if (read > 0) {
            auto left = processMessage(front-version=withfeaturebuf[0..remainder + read]);
            remainder = left.length;
            backbuf[0..remainder] = left; // Copy remainder to backbuf
            left = frontbuf;              // Remember current frontbuf
            frontbuf = backbuf;           // Switch new frontbuf to current backbuf
            backbuf = left;               // And new backbuf is our current frontbuf
            return true;
        } else {
            return false;
        }
    }

    void send(BitHordeMessage m)
    {
        auto msgbuf = m.encode(msgbuf);
        enc_varint!(ushort)(msgbuf.length, szbuf);
        socket.write(szbuf.data);
        socket.write(msgbuf);
    }

    void hangup()
    {
        socket.close();
    }
private:
    ubyte[] processMessage(ubyte[] data)
    {
        auto buf = data;
        uint msglen = dec_varint!(uint)(buf);
        if (buf == data || buf.length < msglen) {
            return data; // Not enough data in buffer
        } else {
            auto msg = new BitHordeMessage();
            msg.decode(buf[0..msglen]);
            Stdout(msg).newline;
            return buf[msglen..length];
        }
    }
}
