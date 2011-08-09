/****************************************************************************************
 *   Copyright: Copyright (C) 2009-2010 Ulrik Mikaelsson. All rights reserved
 *
 *   License:
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 ***************************************************************************************/
module daemon.server;

// TraceExceptions is disabled by default since it works poorly with SIGSEGV without Stdout/Stderr.
// private import tango.core.tools.TraceExceptions;

private import tango.core.Exception;
private import tango.core.Thread;
private import tango.io.FilePath;
private import tango.net.device.Berkeley;
private import tango.net.device.LocalSocket;
private import tango.net.device.Socket;
private import tango.net.InternetAddress;
private import tango.stdc.errno;
private import tango.stdc.posix.sys.stat;
private import tango.stdc.signal;
private import unistd = tango.stdc.posix.unistd;
private import Text = tango.text.Util;
private import tango.sys.Common;
private import tango.time.Clock;
private import tango.util.container.more.Stack;
private import tango.util.Convert;
private import tango.util.log.Log;

private import daemon.store.cache.manager;
private import daemon.store.repository;
private import daemon.client;
private import daemon.config;
private import daemon.routing.friend;
private import daemon.routing.router;
private import lib.asset;
private import lib.connection;
private import lib.httpserver;
private import lib.pumping;
private import message = lib.message;

class Server : IAssetSource
{
    class ConnectionWrapper(T) : BaseSocketServer!(T, FilteredSocket) {
        this(Pump p, T s) { super(p,s); }
        Connection onConnection(Socket s) {
            return _hookupConnection(s);
        }
    }
package:
    CacheManager cacheMgr;
    Repository[] linkRepos;
    Router router;
    Friend[char[]] offlineFriends;
    Thread serverThread;
    Thread reconnectThread;
    ConnectionWrapper!(ServerSocket) tcpServer;
    ConnectionWrapper!(LocalServerSocket) unixServer;
    HTTPPumpingServer httpServer;
    bool running = true;

    Client[char[]] connectedClients;

    Pump pump;

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

        // Setup Pump
        this.pump = new Pump([], 16);

        // Setup servers
        log.info("Listening to tcp-port {}", config.port);
        auto tcpServerSocket = new ServerSocket(new InternetAddress(IPv4Address.ADDR_ANY, config.port), 32, true);
        tcpServer = new typeof(tcpServer)(pump, tcpServerSocket);

        if (config.unixSocket) {
            auto sockF = new FilePath(config.unixSocket);
            auto old_mask = umask(0); // Temporarily clear umask so socket is mode 777
            scope(exit) umask(old_mask);
            if (sockF.exists())
                sockF.remove();
            log.info("Listening to unix-socket {}", config.unixSocket);
            auto unixServerSocket = new LocalServerSocket(config.unixSocket);
            unixServer = new typeof(unixServer)(pump, unixServerSocket);
        }

        if (config.httpPort) {
            auto proxy = new HTTPMgmtProxy("BitHorded Monitor", &onManagementRequest);
            httpServer = new HTTPPumpingServer(pump, "localhost", config.httpPort, &proxy.opCall);
        }

        // Setup helper functions, routing and caching
        this.router = new Router();
        this.cacheMgr = new CacheManager(config.cachedir, config.cacheMaxSize, config.usefsync, router, pump);

        foreach (root; config.linkroots)
            linkRepos ~= new Repository(pump, root, config.usefsync);

        // Setup friend connections
        foreach (f;config.friends)
            this.offlineFriends[f.name] = f;

        log.info("Started");
    }

    void run() {
        cacheMgr.start();
        foreach (repo; linkRepos)
            repo.start();
        serverThread = Thread.getThis;
        scope(exit) { cleanup(); } // Make sure to clean up
        reconnectThread = new Thread(&reconnectLoop);
        reconnectThread.isDaemon = true;
        reconnectThread.start();

        pump.run();
    }

    /************************************************************************************
     * Runs shutdown. Set running to false and close pump.
     ***********************************************************************************/
    synchronized void shutdown() {
        running = false;
        tcpServer.close();
        unixServer.close();
        pump.close();
    }

    /************************************************************************************
     * Cleans up after server ending. Closes connections and shuts down server.
     ***********************************************************************************/
    private void cleanup() {
        running = false;
        try {
            cacheMgr.shutdown();
        } catch (Exception e) {
            log.error("Error in cleanup {}", e);
        } finally {
            serverThread = null;
        }
    }

    bool findAsset(BindRead req) {
        foreach (repo; linkRepos) {
            if (repo.findAsset(req))
                return true;
        }
        return cacheMgr.findAsset(req);
    }

    void uploadAsset(message.BindWrite req, BHAssetStatusCallback cb) {
        if (req.sizeIsSet) {
            cacheMgr.uploadAsset(req, cb);
        } else if (req.pathIsSet) {
            auto basePath = req.path;
            auto _ = Text.tail(basePath, "/", basePath);
            while (basePath) {
                foreach (repo; linkRepos) {
                    if (repo.root == basePath)
                        return repo.uploadAsset(req.path[basePath.length+1..$], cb);
                }
                _ = Text.tail(basePath, "/", basePath);
            }
            log.error("BindWrite with link '{}' did not match any repository.", req.path);
            cb(null, message.Status.NOTFOUND, null);
        } else {
            log.error("Invalid BindWrite with neither size nor path");
        }
    }

protected:
    /************************************************************************************
     * Handles incoming management-requests
     ***********************************************************************************/
    MgmtEntry[] onManagementRequest(char[][] path) {
        if (path.length > 0) switch (path[0]) {
            case "friends":
                return router.onManagementRequest(path[1..$]);
            case "cache":
                return cacheMgr.onManagementRequest(path[1..$]);
            case "connections":
                return clientManagement(path[1..$]);
            default:
                throw new HTTPMgmtProxy.Error(404, "Not found");
        } else {
            auto cacheStats = to!(char[])(cacheMgr.assetCount) ~ ": " ~ to!(char[])(cacheMgr.size / (1024.0*1024*1024)) ~ "GB";
            return [
                MgmtEntry.link("friends", to!(char[])(router.friendCount)),
                MgmtEntry.link("cache", cacheStats),
                MgmtEntry.link("connections", to!(char[])(connectedClients.length))
            ];
        }
    }

    MgmtEntry[] clientManagement(char[][] path) {
        if (path.length > 0) {
            throw new HTTPMgmtProxy.Error(404, "Not found");
        } else {
            MgmtEntry[] res;
            foreach (c; connectedClients) {
                auto downstreamAssetCount = to!(char[])(c.downstreamAssetCount);
                auto upstreamAssetCount = to!(char[])(c.upstreamAssetCount);
                auto desc = "-"~downstreamAssetCount~"+"~upstreamAssetCount~", "~c.peerAddress.toString;
                res ~= MgmtEntry(c.peername, desc);
            }
            return res;
        }
    }

    /************************************************************************************
     * Hooks up given socket into this server, wrapping it to a Connection, assigning to
     * a Client, and add it to the Pump.
     ***********************************************************************************/
    Connection _hookupConnection(Socket s) {
        auto conn = _createConnection(s);
        auto c = new Client(this, conn);
        c.authenticated.attach(&onClientConnect);
        return conn;
    }

    /************************************************************************************
     * Overridable connection Factory, so tests can hook up special connections.
     ***********************************************************************************/
    Connection _createConnection(Socket s) {
        auto c = new Connection(pump, s);
        c.heartbeatInterval = config.heartbeat;
        return c;
    }

    void onClientConnect(lib.client.Client _c)
    {
        Friend f;
        auto c = cast(daemon.client.Client)_c;
        auto peername = c.peername;

        c.disconnected.attach(&onClientDisconnect);
        connectedClients[peername] = c;

        synchronized (this) if (peername in offlineFriends) {
            f = offlineFriends[peername];
            offlineFriends.remove(peername);
            f.connected(cast(daemon.client.Client)c);
            router.registerFriend(f);
        }

        log.info("{} {} connected: {}", f?"Friend":"Client", peername, c.peerAddress);
    }

    void onClientDisconnect(lib.client.Client _c)
    {
        auto c = cast(daemon.client.Client)_c;
        auto f = router.unregisterFriend(c);
        if (f) {
            f.disconnected();
            synchronized (this) offlineFriends[f.name] = f;
        }
        connectedClients.remove(c.peername);
        log.info("{} {} disconnected", f?"Friend":"Client", c.peername);
    }

    void reconnectLoop() {
        /********************************************************************************
         * Tries to (re)connect to single friend.
         * Returns: True if the socket has been consumed, False otherwise
         *******************************************************************************/
        bool tryConnectFriend(Friend f, Socket s) {
            bool consumed = false;
            try {
                s.connect(f.findAddress);
                consumed = true;
                auto c = _hookupConnection(s);
                c.sayHello(name, f.sendCipher, f.sharedKey);
            } catch (SocketException e) {
            } catch (Exception e) {
                log.error("Caught unexpected exception {} while connecting to friend '{}'", e, f.name);
            }
            return consumed;
        }

        auto socket = new Socket();
        while (running) try {
            // Copy friends-list, since it may be modified
            Friend[] tmpOfflineFriends;
            synchronized (this) tmpOfflineFriends = this.offlineFriends.values;
            foreach (friend; tmpOfflineFriends) {
                if ((!friend.isConnected) && tryConnectFriend(friend, socket))
                    socket = new Socket();
                    // Friend may have connected while trying to connect others
                    continue;
            }
            Thread.sleep(15);
        } catch (Exception e) {
            log.error("Caught unexpected exception in reconnectLoop: {}", e);
        }
    }
}
