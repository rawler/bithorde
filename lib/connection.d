module lib.connection;

private import tango.io.Stdout;
private import tango.net.SocketConduit;
private import tango.util.container.LinkedList;

private import lib.protobuf;
public import lib.message;

class Connection
{
private:
    SocketConduit socket;
    ubyte[] frontbuf, backbuf;
    uint remainder;
    ByteBuffer msgbuf, szbuf;
    BitHordeMessage[uint] inFlightMessages;
    LinkedList!(BitHordeMessage) availableRequests;
public:
    this(SocketConduit s)
    {
        this.socket = s;
        this.frontbuf = new ubyte[4096];
        this.backbuf = new ubyte[4096];
        this.remainder = 0;
        this.szbuf = new ByteBuffer(16);
        this.msgbuf = new ByteBuffer(4096);
        this.availableRequests = new LinkedList!(BitHordeMessage);
        for (auto i = 0; i < 16; i++) {
            auto msg = new BitHordeMessage;
            msg.id = i;
            availableRequests.add(msg);
        }
    }

    bool read()
    {
        int read = socket.read(frontbuf[remainder..length]);
        if (read > 0) {
            ubyte[] buf, left = frontbuf[0..remainder + read];
            while (buf != left) {
                buf = left;
                left = processMessage(buf);
            }
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

    void sendRequest(BitHordeMessage.Type t, ProtoBufMessage content)
    {
        auto msg = availableRequests.removeHead();
        inFlightMessages[msg.id] = msg;
        msg.type = t;
        msg.content = content.encode();
        _send(msg);
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

    void _send(BitHordeMessage m)
    {
        szbuf.reset();
        msgbuf.reset();
        auto msgbuf = m.encode(msgbuf);
        enc_varint!(ushort)(msgbuf.length, szbuf);
        socket.write(szbuf.data);
        socket.write(msgbuf);
    }
}
