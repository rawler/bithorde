module daemon.server;

private import tango.io.selector.SelectSelector;
private import tango.io.Stdout;
private import tango.net.ServerSocket;
private import tango.net.Socket;
private import tango.net.SocketConduit;

private import lib.protobuf;

class Connection
{
private:
    SocketConduit socket;
    ubyte[] frontbuf, backbuf;
    uint remainder;
public:
    this(SocketConduit s)
    {
        this.socket = s;
        this.frontbuf = new ubyte[4096];
        this.backbuf = new ubyte[4096];
    }

    bool read()
    {
        int read = socket.read(frontbuf[remainder..length]);
        if (read > 0) {
            auto left = processMessage(frontbuf[0..remainder + read]);
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
            Stdout(cast(char[])buf[0..msglen]).flush;
            return buf[msglen..length];
        }
    }
}

class Server : ServerSocket
{
private:
    ISelector selector;
public:
    this()
    {
        super(new InternetAddress(IPv4Address.ADDR_ANY, 4567), 32, true);
        this.selector = new SelectSelector;
        selector.register(this, Event.Read);
        
    }

    public void run()
    {
        while (selector.select() > 0) {
            SelectionKey[] removeThese;
            foreach (SelectionKey event; selector.selectedSet()) {
                if (!processSelectEvent(event))
                    removeThese ~= event;
            }
            foreach (event; removeThese) {
                auto c = cast(Connection)event.attachment;
                selector.unregister(event.conduit);
                c.hangup();
            }
        }
    }
private:
    void onClientConnect()
    {
        auto s = accept();
        auto c = new Connection(s);
        selector.register(s, Event.Read, c);
    }

    bool processSelectEvent(SelectionKey event)
    {
        if (event.conduit is this) {
            assert(event.isReadable);
            onClientConnect();
        } else {
            auto c = cast(Connection)event.attachment;
            if (event.isError || event.isHangup || event.isInvalidHandle) {
                return false;
            } else {
                assert (event.isReadable);
                return c.read();
            }
        }
        return true;
    }
}

/**
 * Main entry for server daemon
 */
public int main(char[][] args)
{
    Server s = new Server();
    s.run();

    return 0;
}