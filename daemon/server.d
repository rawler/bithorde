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
private import tango.core.tools.TraceExceptions; // Disabled due to poor Tracing-performance.
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

private import daemon.cache.manager;
private import daemon.client;
private import daemon.config;
private import daemon.routing.friend;
private import daemon.routing.router;
private import lib.asset;
private import lib.connection;
private import lib.pumping;
private import message = lib.message;

class Server : IAssetSource
{
    class ConnectionWrapper(T) : BaseSocketServer!(T) {
        this(Pump p, T s) { super(p,s); }
        Connection onConnection(Socket s) {
            return _hookupSocket(s);
        }
    }
package:
    CacheManager cacheMgr;
    Router router;
    Friend[char[]] offlineFriends;
    Thread serverThread;
    Thread reconnectThread;
    ConnectionWrapper!(ServerSocket) tcpServer;
    ConnectionWrapper!(LocalServerSocket) unixServer;
    bool running = true;

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

        // Setup helper functions, routing and caching
        this.router = new Router();
        this.cacheMgr = new CacheManager(config.cachedir, config.cacheMaxSize, config.usefsync, router);

        // Setup friend connections
        foreach (f;config.friends)
            this.offlineFriends[f.name] = f;

        log.info("Started");
    }

    void run() {
        cacheMgr.start();
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

    void findAsset(BindRead req) {
        return cacheMgr.findAsset(req);
    }

    void uploadAsset(message.BindWrite req, BHAssetStatusCallback cb) {
        cacheMgr.uploadAsset(req, cb);
    }

protected:
    /************************************************************************************
     * Hooks up given socket into this server, wrapping it to a Connection, assigning to
     * a Client, and add it to the Pump.
     ***********************************************************************************/
    Connection _hookupSocket(Socket s) {
        auto conn = _createConnection(s);
        auto c = new Client(this, conn);
        c.authenticated.attach(&onClientConnect);
        return conn;
    }

    /************************************************************************************
     * Overridable connection Factory, so tests can hook up special connections.
     ***********************************************************************************/
    Connection _createConnection(Socket s) {
        return new Connection(pump, s);
    }

    void onClientConnect(lib.client.Client c)
    {
        Friend f;
        auto peername = c.peername;

        c.disconnected.attach(&onClientDisconnect);

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
                _hookupSocket(s);
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
