module daemon.server;

private import tango.core.Exception;
private import tango.core.Thread;
private import tango.io.selector.Selector;
private import tango.io.Stdout;
private import tango.net.ServerSocket;
private import tango.net.Socket;
private import tango.net.SocketConduit;
private import tango.stdc.posix.signal;
private import Text = tango.text.Util;
private import tango.util.container.more.Stack;
private import tango.util.Convert;

private import daemon.cache;
private import daemon.client;
private import daemon.friend;
private import daemon.router;
private import lib.asset;
private import lib.message;

interface IAssetSource {
    IServerAsset getAsset(BitHordeMessage.HashType hType, ubyte[] id, ulong reqid, ubyte priority, BHServerOpenCallback callback, Client origin);
}

class Server : ServerSocket, IAssetSource
{
package:
    ISelector selector;
    CacheManager cacheMgr;
    Router router;
    Friend[char[]] offlineFriends;
    Thread reconnectThread;
    char[] name;
public:
    this(char[] name, ushort port, Friend[] friends)
    {
        super(new InternetAddress(IPv4Address.ADDR_ANY, port), 32, true);
        this.name = name;
        this.selector = new Selector;
        this.selector.open(10,10);
        selector.register(this, Event.Read);
        this.cacheMgr = new CacheManager(".");
        this.router = new Router(this);
        foreach (f;friends)
            this.offlineFriends[f.name] = f;
        this.reconnectThread = new Thread(&reconnectLoop);
        this.reconnectThread.start();
    }

    void run()
    {
        while (selector.select() > 0) {
            SelectionKey[] removeThese;
            foreach (SelectionKey event; selector.selectedSet()) {
                if (!processSelectEvent(event))
                    removeThese ~= event;
            }
            foreach (event; removeThese) {
                auto c = cast(Client)event.attachment;
                onClientDisconnect(c);
                selector.unregister(event.conduit);
                delete c;
            }
        }
    }

    IServerAsset getAsset(BitHordeMessage.HashType hType, ubyte[] id, ulong reqid, ubyte priority, BHServerOpenCallback callback, Client origin) {
        return router.getAsset(hType, id, reqid, priority, callback, origin);
    }
private:
    void onClientConnect(SocketConduit s)
    {
        auto c = new Client(this, s);
        Friend f;
        auto peername = c.peername;
        if (peername in offlineFriends) {
            f = offlineFriends[peername];
            offlineFriends.remove(peername);
            f.c = c;
            router.registerFriend(f);
        }
        selector.register(s, Event.Read, c);
        Stderr.format("{} {} connected: {}", f?"Friend":"Client", peername, s.socket.remoteAddress).newline;
    }

    void onClientDisconnect(Client c)
    {
        auto f = router.unregisterFriend(c);
        if (f) {
            f.c = null;
            offlineFriends[f.name] = f;
        }
        Stderr.format("{} disconnected", f?f.name:"Client").newline;
        return c;
    }

    bool processSelectEvent(SelectionKey event)
    {
        if (event.conduit is this) {
            assert(event.isReadable);
            onClientConnect(accept());
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

    bool attemptConnect(InternetAddress friend) {
        auto socket = new SocketConduit();
        socket.connect(friend);
        onClientConnect(socket);
        return true;
    }

    void reconnectLoop() {
        auto socket = new SocketConduit();
        while (true) try {
            foreach (friend; offlineFriends.values) try {
                socket.connect(friend.addr);
                onClientConnect(socket);
                socket = new SocketConduit();
            } catch (SocketException e) {}
            Thread.sleep(2);
        } catch (Exception e) {
            Stderr.format("Caught unexpected exceptin in reconnectLoop: {}", e).newline;
        }
    }
}

/**
 * Main entry for server daemon
 */
public int main(char[][] args)
{
    if (args.length<2) {
        Stderr.format("Usage: {} <name> <server-port> [friend1:ip:port] [friend2:ip:port] ...", args[0]).newline;
        return -1;
    }

    // Hack, since Tango doesn't set MSG_NOSIGNAL on send/recieve, we have to explicitly ignore SIGPIPE
    signal(SIGPIPE, SIG_IGN);

    auto name = args[1];
    auto port = to!(uint)(args[2]);

    Friend[] friends;
    foreach (arg; args[3..length]) {
        char[][] part = Text.delimit(arg, ":");
        friends ~= new Friend(part[0], new InternetAddress(part[1], to!(ushort)(part[2])));
    }

    Server s = new Server(name, port, friends);
    s.run();

    return 0;
}