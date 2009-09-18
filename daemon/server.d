module daemon.server;

private import tango.io.selector.SelectSelector;
private import tango.io.Stdout;
private import tango.net.ServerSocket;
private import tango.net.Socket;
private import tango.net.SocketConduit;

private import daemon.cache;
private import daemon.client;

class Server : ServerSocket
{
package:
    ISelector selector;
    CacheManager cacheMgr;
public:
    this()
    {
        super(new InternetAddress(IPv4Address.ADDR_ANY, 4567), 32, true);
        this.selector = new SelectSelector;
        selector.register(this, Event.Read);
        this.cacheMgr = new CacheManager(".");
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
                auto c = cast(Client)event.attachment;
                selector.unregister(event.conduit);
                c.hangup();
            }
        }
    }
private:
    void onClientConnect()
    {
        auto s = accept();
        auto c = new Client(this, s);
        selector.register(s, Event.Read, c);
    }

    bool processSelectEvent(SelectionKey event)
    {
        if (event.conduit is this) {
            assert(event.isReadable);
            onClientConnect();
        } else {
            auto c = cast(Client)event.attachment;
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