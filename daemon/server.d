module daemon.server;

private import tango.core.Exception;
private import tango.core.Thread;
private import tango.io.FilePath;
private import tango.io.selector.Selector;
private import tango.net.device.Berkeley;
private import tango.net.device.LocalSocket;
private import tango.net.device.Socket;
private import tango.net.InternetAddress;
private import Text = tango.text.Util;
private import tango.time.Clock;
private import tango.util.container.more.Stack;
private import tango.util.Convert;
private import tango.util.log.Log;

private import daemon.cache.manager;
private import daemon.client;
private import daemon.config;
private import daemon.routing.friend;
private import daemon.routing.router;
private import lib.asset;
private import lib.connection;
private import message = lib.message;

class Server : IAssetSource
{
package:
    ISelector selector;
    CacheManager cacheMgr;
    Router router;
    Friend[char[]] offlineFriends;
    Thread reconnectThread;
    ServerSocket tcpServer;
    LocalServerSocket unixServer;

    static Logger log;
    static this() {
        log = Log.lookup("daemon.server");
    }
public:
    char[] name;
    Config config;
    this(Config config)
    {
        // Setup basics
        this.config = config;
        this.name = config.name;

        // Setup selector
        this.selector = new Selector;
        this.selector.open(10,10);

        // Setup servers
        log.info("Listening to tcp-port {}", config.port);
        this.tcpServer = new ServerSocket(new InternetAddress(IPv4Address.ADDR_ANY, config.port), 32, true);
        selector.register(tcpServer, Event.Read);
        if (config.unixSocket) {
            auto sockF = new FilePath(config.unixSocket);
            if (sockF.exists())
                sockF.remove();
            log.info("Listening to unix-socket {}", config.unixSocket);
            this.unixServer = new LocalServerSocket(config.unixSocket);
            selector.register(unixServer, Event.Read);
        }

        // Setup helper functions, routing and caching
        this.router = new Router();
        this.cacheMgr = new CacheManager(config.cachedir, router);

        // Setup friend connections
        foreach (f;config.friends)
            this.offlineFriends[f.name] = f;

        log.info("Started");
    }
    ~this() {
        if (tcpServer)
            tcpServer.socket.detach();
        if (unixServer)
            unixServer.socket.detach();
    }

    void run() {
        this.reconnectThread = new Thread(&reconnectLoop);
        this.reconnectThread.isDaemon = true;
        this.reconnectThread.start();

        while (true)
            pump();
    }

    protected void pump()
    {
        scope SelectionKey[] removeThese;
        auto nextDeadline = Time.max;
        foreach (key; selector) {
            auto c = cast(Connection)key.attachment;
            if (c && c.timeouts.size && (c.timeouts.peek.time < nextDeadline))
                nextDeadline = c.timeouts.peek.time;
        }
        if (selector.select(nextDeadline - Clock.now) > 0) {
            foreach (SelectionKey event; selector.selectedSet()) {
                if (!processSelectEvent(event))
                    removeThese ~= event;
            }
        }
        foreach (key; selector) {
            auto c = cast(Connection)key.attachment;
            if (c) c.processTimeouts();
        }
        foreach (event; removeThese) {
            auto c = cast(Client)event.attachment;
            onClientDisconnect(c);
            selector.unregister(event.conduit);
            c.close();
            delete c;
        }
    }

    IServerAsset findAsset(OpenRequest req, BHServerOpenCallback cb) {
        return cacheMgr.findAsset(req, cb);
    }

    IServerAsset uploadAsset(UploadRequest req) {
        auto asset = cacheMgr.uploadAsset(req);
        req.callback(asset, message.Status.SUCCESS);
        return asset;
    }
protected:
    void onClientConnect(Client c)
    {
        Friend f;
        auto peername = c.peername;
        if (peername in offlineFriends) {
            f = offlineFriends[peername];
            offlineFriends.remove(peername);
            f.connected(c);
            router.registerFriend(f);
        }

        log.info("{} {} connected: {}", f?"Friend":"Client", peername, c.remoteAddress);
    }

    void onClientDisconnect(Client c)
    {
        auto f = router.unregisterFriend(c);
        if (f) {
            f.disconnected();
            offlineFriends[f.name] = f;
        }
        log.info("{} {} disconnected", f?"Friend":"Client", c.peername);
    }

    private bool _processMessageQueue(Client c) {
        try {
            while (c.processMessage()) {}
            return true;
        } catch (Exception e) {
            char[] excInfo = "";
            e.writeOut(delegate(char[] msg){excInfo ~= msg;});
            log.fatal("Connection {} recieved triggered an unhandled exception; {}", c.peername, excInfo);
            return false;
        }
    }

    private bool _handshakeAndSetup(Socket s) {
        bool abortSocket() {
            s.shutdown();
            s.close();
            return false;
        }
        Client c;
        try {
            c = new Client(this, s);
        } catch (Exception e) {
            char[] excInfo = "";
            e.writeOut(delegate(char[] msg){excInfo ~= msg;});
            log.fatal("New connection triggered an unhandled exception; {}", excInfo);
            return abortSocket();
        }
        onClientConnect(c);
        selector.register(s, Event.Read, c);

        // ATM, there may be stale data in the buffers from the HandShake that needs processing
        // Perhaps try to rework internal API so that the HandShake is handled in normal run-loop?
        if (!_processMessageQueue(c)) {
            onClientDisconnect(c);
            return abortSocket();
        }
        return true;
    }

    bool processSelectEvent(SelectionKey event)
    {
        if (event.conduit is tcpServer) {
            assert(event.isReadable);
            _handshakeAndSetup(tcpServer.accept());
        } else if (event.conduit is unixServer) {
            assert(event.isReadable);
            _handshakeAndSetup(unixServer.accept());
        } else {
            auto c = cast(Client)event.attachment;
            if (event.isError || event.isHangup || event.isInvalidHandle) {
                return false;
            } else {
                assert (event.isReadable);
                if (c.readNewData())
                    return _processMessageQueue(c);
                else
                    return false;
            }
        }
        return true;
    }

    void reconnectLoop() {
        auto socket = new Socket();
        while (true) try {
            foreach (friend; offlineFriends.values) {
                try {
                    socket.connect(friend.addr);
                    _handshakeAndSetup(socket);
                    socket = new Socket();
                } catch (SocketException e) {}
            }
            Thread.sleep(2);
        } catch (Exception e) {
            log.error("Caught unexpected exception in reconnectLoop: {}", e);
        }
    }
}