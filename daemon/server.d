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

private import tango.core.Exception;
private import tango.core.Thread;
// private import tango.core.tools.TraceExceptions; // Disabled due to poor Tracing-performance.
private import tango.io.FilePath;
private import tango.io.selector.Selector;
private import tango.net.device.Berkeley;
private import tango.net.device.LocalSocket;
private import tango.net.device.Socket;
private import tango.net.InternetAddress;
private import tango.stdc.posix.sys.stat;
private import tango.stdc.signal;
private import unistd = tango.stdc.posix.unistd;
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

version (linux) {
    extern (C) int eventfd(uint initval, int flags);
    class EventFD : ISelectable {
        int _handle;
        Handle fileHandle() { return cast(Handle)_handle; }
        this() {
            _handle = eventfd(0, 0);
        }
        ~this() {
            unistd.close (_handle);
        }
        void signal() {
            static ulong add = 1;
            auto written = unistd.write(_handle, &add, add.sizeof);
        }
        void clear() {
            static ulong res;
            unistd.read(_handle, &res, res.sizeof);
        }
    }
} else {
    static assert(0, "Server needs abort-implementation for non-linux OS");
}

class Server : IAssetSource
{
package:
    ISelector selector;
    CacheManager cacheMgr;
    Router router;
    Friend[char[]] offlineFriends;
    Thread serverThread;
    Thread reconnectThread;
    ServerSocket tcpServer;
    LocalServerSocket unixServer;
    bool running = true;
    EventFD evfd;               /// Used for sending events breaking select

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
        this.running = true;

        // Setup selector
        this.selector = new Selector;
        this.selector.open(10, 10);

        // Setup event selector
        this.evfd = new EventFD;
        this.selector.register(evfd, Event.Read);

        // Setup servers
        log.info("Listening to tcp-port {}", config.port);
        this.tcpServer = new ServerSocket(new InternetAddress(IPv4Address.ADDR_ANY, config.port), 32, true);
        selector.register(tcpServer, Event.Read);
        if (config.unixSocket) {
            auto sockF = new FilePath(config.unixSocket);
            auto old_mask = umask(0); // Temporarily clear umask so socket is mode 777
            scope(exit) umask(old_mask);
            if (sockF.exists())
                sockF.remove();
            log.info("Listening to unix-socket {}", config.unixSocket);
            this.unixServer = new LocalServerSocket(config.unixSocket);
            selector.register(unixServer, Event.Read);
        }

        // Setup helper functions, routing and caching
        this.router = new Router();
        this.cacheMgr = new CacheManager(config.cachedir, config.cacheMaxSize, config.usefsync, router);

        // Setup friend connections
        foreach (f;config.friends)
            this.offlineFriends[f.name] = f;

        log.info("Started");
    }

    ~this() {
        running = false;
    }

    void run() {
        cacheMgr.start();
        serverThread = Thread.getThis;
        scope(exit) { cleanup(); } // Make sure to clean up
        reconnectThread = new Thread(&reconnectLoop);
        reconnectThread.isDaemon = true;
        reconnectThread.start();

        while (running)
            pump();
    }

    /************************************************************************************
     * Cleans up after server ending. Closes connections and shuts down server.
     ***********************************************************************************/
    private void cleanup() {
        running = false;
        try {
            foreach (sk; selector) {
                auto sock = cast(Socket)(sk.conduit);
                if (sock) {
                    sock.shutdown();
                    sock.detach();
                }
            }
            tcpServer = null;
            unixServer = null;
            cacheMgr.shutdown();
        } catch (Exception e) {
            log.error("Error in cleanup {}", e);
        } finally {
            serverThread = null;
        }
    }

    /************************************************************************************
     * Runs shutdown. Set running to false and signal evfd.
     ***********************************************************************************/
    synchronized void shutdown() {
        running = false;
        evfd.signal();
        // Wait for cleanup, unless we're the thread supposed to do the cleanup.
        while (serverThread && (serverThread != Thread.getThis)) {
            Thread.sleep(0.1);
            evfd.signal();
        }
    }

    protected void pump()
    {
        scope SelectionKey[] removeThese;
        auto nextDeadline = Time.max;
        foreach (key; selector) {
            if (auto c = cast(Client)key.attachment) {
                auto cnd = c.nextDeadline;
                if (cnd < nextDeadline) nextDeadline = cnd;
            }
        }
        auto timeout = nextDeadline - Clock.now;
        if (timeout > TimeSpan.zero) {
            auto triggers = selector.select(timeout);
            if (!running) // Shutdown started
                return;
            if (triggers > 0) {
                foreach (SelectionKey event; selector.selectedSet()) {
                    if (event.isError || event.isHangup || event.isInvalidHandle ||
                            !processSelectEvent(event))
                        removeThese ~= event;
                }
            }
        }
        auto now = Clock.now;
        foreach (key; selector) {
            auto c = cast(Client)key.attachment;
            if (c) c.processTimeouts(now);
        }
        foreach (event; removeThese) {
            selector.unregister(event.conduit);
            if (auto c = cast(Client)event.attachment) { // Connection has attached client
                try {
                    onClientDisconnect(c);
                    c.close();
                } catch (Exception e) {
                    if (e.file && e.line)
                        log.error("Exception when closing client {} ({}:{})", e, e.file, e.line);
                    else
                        log.error("Exception when closing client {}", e);
                }
            }
        }
    }

    void findAsset(BindRead req) {
        return cacheMgr.findAsset(req);
    }

    void uploadAsset(message.BindWrite req, BHAssetStatusCallback cb) {
        cacheMgr.uploadAsset(req, cb);
    }
protected:
    void onClientConnect(Client c, Connection conn)
    {
        Friend f;
        auto peername = c.peername;

        synchronized (this) if (peername in offlineFriends) {
            f = offlineFriends[peername];
            offlineFriends.remove(peername);
            f.connected(c);
            router.registerFriend(f);
        }

        log.info("{} {} connected: {}", f?"Friend":"Client", peername, conn.remoteAddress);
    }

    void onClientDisconnect(Client c)
    {
        auto f = router.unregisterFriend(c);
        if (f) {
            f.disconnected();
            synchronized (this) offlineFriends[f.name] = f;
        }
        log.info("{} {} disconnected", f?"Friend":"Client", c.peername);
    }

    protected bool _processMessageQueue(Connection c) {
        try {
            while (c.processMessage()) {}
            return true;
        } catch (Exception e) {
            char[] excInfo = "";
            e.writeOut(delegate(char[] msg){excInfo ~= msg;});
            log.fatal("Connection {} triggered an unhandled exception; {}", c.peername, excInfo);
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
        onClientConnect(c, c.connection);
        selector.register(s, Event.Read, c);

        // ATM, there may be stale data in the buffers from the HandShake that needs processing
        // Perhaps try to rework internal API so that the HandShake is handled in normal run-loop?
        if (!_processMessageQueue(c.connection)) {
            onClientDisconnect(c);
            return abortSocket();
        }
        return true;
    }

    bool processSelectEvent(SelectionKey event)
    in { assert(event.isReadable); }
    body {
        if (event.conduit is tcpServer) {
            _handshakeAndSetup(tcpServer.accept());
        } else if (event.conduit is unixServer) {
            _handshakeAndSetup(unixServer.accept());
        } else if (event.conduit is evfd) {
            evfd.clear();
        } else {
            auto c = cast(Client)event.attachment;
            if (c.connection.readNewData())
                return _processMessageQueue(c.connection);
            else
                return false;
        }
        return true;
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
                _handshakeAndSetup(s);
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