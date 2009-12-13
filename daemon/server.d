module daemon.server;

private import tango.core.Exception;
private import tango.core.Thread;
private import tango.io.FilePath;
private import tango.io.selector.Selector;
private import tango.io.Stdout;
private import tango.net.device.Berkeley;
private import tango.net.device.LocalSocket;
private import tango.net.device.Socket;
private import tango.net.InternetAddress;
private import tango.stdc.posix.signal;
private import Text = tango.text.Util;
private import tango.util.container.more.Stack;
private import tango.util.Convert;
private import tango.util.log.AppendConsole;
private import tango.util.log.LayoutDate;
private import tango.util.log.Log;

private import daemon.cache;
private import daemon.client;
private import daemon.config;
private import daemon.friend;
private import daemon.router;
private import lib.asset;
private import lib.client : bytesToHex;
private import message = lib.message;

interface IAssetSource {
    IServerAsset findAsset(OpenRequest req, Client origin);
}

class Server : IAssetSource
{
package:
    ISelector selector;
    CacheManager cacheMgr;
    Router router;
    Friend[char[]] offlineFriends;
    Thread reconnectThread;
    char[] name;
    ServerSocket tcpServer;
    ServerSocket unixServer;

    static Logger log;
    static this() {
        log = Log.lookup("daemon.server");
    }
public:
    this(Config config)
    {
        // Setup basics
        this.name = config.name;

        // Setup selector
        this.selector = new Selector;
        this.selector.open(10,10);

        // Setup servers
        this.tcpServer = new ServerSocket(new InternetAddress(IPv4Address.ADDR_ANY, config.port), 32, true);
        selector.register(tcpServer, Event.Read);
        if (config.unixSocket) {
            auto sockF = new FilePath(config.unixSocket);
            if (sockF.exists())
                sockF.remove();
            this.unixServer = new ServerSocket(new LocalAddress(config.unixSocket), 32, true);
            selector.register(unixServer, Event.Read);
        }

        // Setup helper functions, routing and caching
        this.cacheMgr = new CacheManager(config.cachedir);
        this.router = new Router(this);

        // Setup friend connections
        foreach (f;config.friends)
            this.offlineFriends[f.name] = f;
        this.reconnectThread = new Thread(&reconnectLoop);
        this.reconnectThread.start();

        log.info("Started");
    }
    ~this() {
        this.tcpServer.socket.detach();
        this.unixServer.socket.detach();
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

    IServerAsset findAsset(OpenRequest req, Client origin) {
        auto asset = cacheMgr.findAsset(req);
        if (asset) {
            log.trace("serving {} from cache", bytesToHex(asset.id));
            req.callback(asset, message.Status.SUCCESS);
            return asset;
        } else {
            log.trace("forwarding {}", req);
            return router.findAsset(req, origin);
        }
    }

    IServerAsset uploadAsset(UploadRequest req) {
        auto asset = cacheMgr.uploadAsset(req);
        req.callback(asset, message.Status.SUCCESS);
        return asset;
    }
private:
    void onClientConnect(Socket s)
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

        // ATM, there may be stale data in the buffers from the HandShake that needs processing
        // FIXME: internal API should be re-written so that the HandShake is handled in normal run-loop
        while (c.processMessage()) {}

        log.info("{} {} connected: {}", f?"Friend":"Client", peername, s.socket.remoteAddress);
    }

    void onClientDisconnect(Client c)
    {
        auto f = router.unregisterFriend(c);
        if (f) {
            f.c = null;
            offlineFriends[f.name] = f;
        }
        log.info("{} {} disconnected", f?"Friend":"Client", c.peername);
    }

    bool processSelectEvent(SelectionKey event)
    {
        if (event.conduit is tcpServer) {
            assert(event.isReadable);
            onClientConnect(tcpServer.accept());
        } else if (event.conduit is unixServer) {
            assert(event.isReadable);
            onClientConnect(unixServer.accept());
        } else {
            auto c = cast(Client)event.attachment;
            if (event.isError || event.isHangup || event.isInvalidHandle) {
                return false;
            } else {
                assert (event.isReadable);
                if (c.readNewData())
                    while (c.processMessage()) {}
                else
                    return false;
            }
        }
        return true;
    }

    bool attemptConnect(InternetAddress friend) {
        auto socket = new Socket();
        socket.connect(friend);
        onClientConnect(socket);
        return true;
    }

    void reconnectLoop() {
        auto socket = new Socket();
        while (true) try {
            foreach (friend; offlineFriends.values) try {
                socket.connect(friend.addr);
                onClientConnect(socket);
                socket = new Socket();
            } catch (SocketException e) {}
            Thread.sleep(2);
        } catch (Exception e) {
            log.error("Caught unexpected exception in reconnectLoop: {}", e);
        }
    }
}

/**
 * Main entry for server daemon
 */
public int main(char[][] args)
{
    if (args.length != 2) {
        Stderr.format("Usage: {} <config>", args[0]).newline;
        return -1;
    }

    // Hack, since Tango doesn't set MSG_NOSIGNAL on send/recieve, we have to explicitly ignore SIGPIPE
    signal(SIGPIPE, SIG_IGN);

    auto config = new Config(args[1]);

    auto consoleOut = new AppendConsole(new LayoutDate);
    Log.root.add(consoleOut);

    scope Server s = new Server(config);
    s.run();

    return 0;
}
