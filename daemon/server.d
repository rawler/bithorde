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
    bool running = true;

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
        this.cacheMgr = new CacheManager(config.cachedir, config.cacheMaxSize, router);

        // Setup friend connections
        foreach (f;config.friends)
            this.offlineFriends[f.name] = f;

        log.info("Started");
    }

    ~this() {
        running = false;
    }

    void run() {
        reconnectThread = new Thread(&reconnectLoop);
        scope(exit) { shutdown(); } // Make sure to clean up
        reconnectThread.isDaemon = true;
        reconnectThread.start();

        while (running)
            pump();
    }

    /************************************************************************************
     * Prepares for shutdown. Closes sockets, open files and connections
     ***********************************************************************************/
    synchronized void shutdown() {
        running = false;
        if (tcpServer) {
            tcpServer.shutdown();
            tcpServer.detach();
            tcpServer = null;
        }
        if (unixServer) {
            unixServer.shutdown();
            unixServer.detach();
            unixServer = null;
        }
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
        }
    }

    void findAsset(OpenRequest req) {
        return cacheMgr.findAsset(req);
    }

    void uploadAsset(UploadRequest req) {
        cacheMgr.uploadAsset(req);
    }
protected:
    void onClientConnect(Client c)
    {
        Friend f;
        auto peername = c.peername;

        synchronized (this) if (peername in offlineFriends) {
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
            synchronized (this) offlineFriends[f.name] = f;
        }
        log.info("{} {} disconnected", f?"Friend":"Client", c.peername);
    }

    protected bool _processMessageQueue(Client c) {
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
        while (running) try {
            synchronized (this) foreach (friend; offlineFriends.values) {
                try {
                    socket.connect(friend.findAddress);
                    _handshakeAndSetup(socket);
                    socket = new Socket();
                } catch (SocketException e) {}
            }
            Thread.sleep(15);
        } catch (Exception e) {
            log.error("Caught unexpected exception in reconnectLoop: {}", e);
        }
    }
}