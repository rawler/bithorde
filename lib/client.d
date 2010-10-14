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
module lib.client;

private import tango.core.Exception;
private import tango.io.selector.Selector;
private import tango.math.random.Random;
private import tango.net.device.Socket;
private import tango.text.convert.Format;
private import tango.time.Clock;
private import tango.time.Time;
private import tango.util.container.more.Stack;
private import tango.util.log.Log;
private import tango.util.MinMax;

public import lib.asset;
import lib.connection;
import lib.protobuf;
import lib.timeout;

alias void delegate(Object) DEvent;
extern (C) void rt_attachDisposeEvent(Object h, DEvent e);

const StatInterval = TimeSpan.fromSeconds(60);

/****************************************************************************************
 * RemoteAsset is the basic BitHorde object for tracking a remotely open asset from the
 * client-side.
 ***************************************************************************************/
class RemoteAsset : private IAsset {
    mixin IAsset.StatusSignal;
    public bool singleShotStatus = true;

    /************************************************************************************
     * Internal ReadRequest object, for tracking in-flight readrequests.
     ***********************************************************************************/
    class ReadRequest : message.ReadRequest {
        BHReadCallback _callback;
        ushort retries;
        this(BHReadCallback cb, ushort retries=0) {
            this.handle = this.outer.handle;
            this.retries = retries;
            _callback = cb;
        }
        void callback(message.Status s, message.ReadResponse resp) {
            if ((s == message.Status.TIMEOUT) && retries) {
                retries -= 1;
                client.sendRPCRequest(this);
            } else {
                _callback(this.outer, s, this, resp);
            }
        }
        void abort(message.Status s) {
            callback(s, null);
        }
    }
    bool closed;
    Client client;
private:
    void clientGone(Object o) {
        this.client = null;
    }
protected:
    /************************************************************************************
     * RemoteAssets should only be created from the Client
     ***********************************************************************************/
    this(Client c, message.BindRead req, BHAssetStatusCallback cb, bool singleShotStatus = true) {
        this(c, cb, singleShotStatus);
        this.requestIds = req.ids;
    }
    this(Client c, message.BindWrite req, BHAssetStatusCallback cb, bool singleShotStatus = true) {
        this(c, cb, singleShotStatus);
        this._size = req.size;
    }
    this(Client c, BHAssetStatusCallback cb, bool singleShotStatus) {
        rt_attachDisposeEvent(c, &clientGone); // Add hook for invalidating client-reference
        this.client = c;
        this.handle = c.allocateFreeHandle;
        this.attachWatcher(cb);
        this.singleShotStatus = singleShotStatus;
    }
    ~this() {
        if (!closed)
            close();
    }

    TimeoutQueue.EventId statusTimeout;
    void updateStatus(message.AssetStatus resp) {
        if (statusTimeout.cb.ptr) {
            client.timeouts.abort(statusTimeout);
            statusTimeout = statusTimeout.init;
        }
        if (closed) {
            confirmedClose();
        } else {
            if (resp.sizeIsSet)
                this._size = resp.size;
            scope sig = _statusSignal; // Store away sig for call
            if (singleShotStatus)
                _statusSignal = _statusSignal.init;
            sig.call(this, resp.status, resp);
            if (resp.status != message.Status.SUCCESS)
                close();
        }
    }
    void triggerTimeout(Time deadline, Time now) {
        if (closed) {
            confirmedClose();
        } else {
            statusTimeout = statusTimeout.init;
            scope sig = _statusSignal; // Store away sig for call
            if (singleShotStatus)
                _statusSignal = _statusSignal.init;
            sig.call(this, message.Status.TIMEOUT, null);
        }
    }
    void confirmedClose() {
        if (client) client.onAssetClosed(this);
        client = null;
    }
public:
    ushort handle;
    ulong _size;
    message.Identifier[] requestIds;

    /************************************************************************************
     * aSyncRead as of IAsset. With or without explicit retry-count
     ***********************************************************************************/
    void aSyncRead(ulong offset, uint size, BHReadCallback readCallback) {
        this.aSyncRead(offset, size, readCallback, 5, TimeSpan.fromMillis(6000));
    }
    /// ditto
    void aSyncRead(ulong offset, uint size, BHReadCallback readCallback, ushort retries, TimeSpan timeout) {
        auto req = new ReadRequest(readCallback, retries);
        req.offset = offset;
        req.size = size;
        client.sendRPCRequest(req, timeout);
    }

    void sendDataSegment(ulong offset, ubyte[] data) {
        auto msg = new message.DataSegment;
        msg.handle = handle;
        msg.offset = offset;
        msg.content = data;
        client.sendNotification(msg);
    }

    final ulong size() {
        return _size;
    }

    void close() {
        if (closed)
            return;
        closed = true;
        scope sig = _statusSignal;
        _statusSignal = _statusSignal.init;
        sig.call(this, message.Status.INVALID_HANDLE, null);
        if (client && !client.closed) {
            // Sending null-bind closes the asset
            scope req = new message.BindRead;
            client.sendBindRequest(req, this, TimeSpan.fromSeconds(5));
        }
    }
}

/****************************************************************************************
 * The Client class handles an ongoing client-session with a remote Bithorde-node. The
 * Client is the main-point of the Client API. To access BitHorde, just create a Client
 * with some address, and start fetching.
 *
 * Worth mentioning is that the entire client API is asynchronous, meaning that no remote
 * calls return anything immediately, but later through a required callback.
 *
 * Most applications will want to use the SimpleClient for basic operations.
 *
 * The Client is not thread-safe at this moment.
 ***************************************************************************************/
class Client {
private:
    RemoteAsset[] boundAssets;
    Stack!(ushort) freeAssetHandles;
    ushort nextNewHandle;
    TimeoutQueue timeouts;
    Time nextStatPrint;
    protected Logger log;
public:
    Connection connection;
    /************************************************************************************
     * Create a BitHorde client by name and an IPv4Address, or a LocalAddress.
     ***********************************************************************************/
    this (Address addr, char[] name)
    {
        this(name);
        connect(addr);
    }

    /************************************************************************************
     * Create BitHorde client on provided Socket
     ***********************************************************************************/
    this (Socket s, char[] name) {
        this(name);
        connection.handshake(s);
    }

    /************************************************************************************
     * Private common-initialization ctor
     ***********************************************************************************/
    private this(char[] name) {
        this.log = Log.lookup("lib.client");
        connection = new Connection(name, &process);
        connection.onHandshakeDone.attach = &onConnectionHandshakeDone;
        timeouts = new TimeoutQueue;
        boundAssets = new RemoteAsset[16];
        nextStatPrint = Clock.now + StatInterval;
    }

    /************************************************************************************
     * Connect to specified address
     ***********************************************************************************/
    protected Socket connect(Address addr) {
        auto socket = new Socket(addr.addressFamily, SocketType.STREAM, ProtocolType.IP);
        socket.connect(addr);
        connection.handshake(socket);
        return socket;
    }

    /************************************************************************************
     * As soon as we've got a remote name, let the logger reflect it.
     ***********************************************************************************/
    private void onConnectionHandshakeDone(char[] peername) {
        this.log = Log.lookup("lib.client."~peername);
    }

    char[] peername() {
        return connection.peername;
    }

    void close()
    {
        connection.close();
        foreach (asset; boundAssets) if (asset) {
            asset.close();
        }
        log.trace("Closed...");
    }

    /************************************************************************************
     * Attempt to open an asset identified by any of a set of ids.
     *
     * Params:
     *     ids              = A list of ids to match. Priorities, and outcome of
     *                        conflicts in ID:s are undefined
     *     openCallback     = A callback to be notified when the open request has
     *                        completed
     *     timeout          = (optional) How long to wait before automatically failing
     *                        the request. Defaults to 500msec.
     *     singleShotStatus = The BHAssetStatusCallback will only be called once on
     *                        initial binding, and not for later status updates
     ***********************************************************************************/
    void open(message.Identifier[] ids, BHAssetStatusCallback cb,
        TimeSpan timeout = TimeSpan.fromMillis(10000), bool singleShotStatus = true) {
        open(ids, cb, rand.uniformR2!(ulong)(1,ulong.max), timeout,
             singleShotStatus);
    }

    /************************************************************************************
     * Create a new remote asset for uploading
     ***********************************************************************************/
    void beginUpload(ulong size, BHAssetStatusCallback cb, bool singleShotStatus = false) {
        auto req = new message.BindWrite;
        req.size = size;
        auto asset = new RemoteAsset(this, req, cb, singleShotStatus);
        sendBindRequest(req, asset, TimeSpan.fromMillis(10000));
    }

    /************************************************************************************
     * Measure how loaded this client currently is
     ***********************************************************************************/
    uint getLoad() {
        return connection.getLoad();
    }

    /************************************************************************************
     * Figure next timeout for this asset
     ***********************************************************************************/
    Time nextDeadline() {
        auto result = min!(Time)(timeouts.nextDeadline, connection.nextDeadline);
        result = min!(Time)(result, nextStatPrint);
        return result;
    }

    /************************************************************************************
     * Process any passed timeouts
     ***********************************************************************************/
    void processTimeouts(Time now) {
        timeouts.emit(now);
        connection.processTimeouts(now);
        if (now >= nextStatPrint) {
            connection.counters.doSwitch(now);
            if (!connection.counters.empty)
                log.trace("Stats: {}", connection.counters);
            nextStatPrint = now + StatInterval;
        }
    }
protected:
    synchronized void sendMessage(message.Message msg) {
        connection.sendMessage(msg);
    }

    /************************************************************************************
     * Send message, but don't care about delivery. IE, catch IOExceptions and just
     * ignore them.
     ***********************************************************************************/
    void sendNotification(message.Message msg) {
        try {
            sendMessage(msg);
        } catch (IOException e) {
            log.trace("Ignored exception: {}", e);
        }
    }
    synchronized void sendRPCRequest(message.RPCRequest req,
                                  TimeSpan timeout=TimeSpan.fromMillis(4000)) {
        connection.sendRPCRequest(req, timeout);
    }

    /************************************************************************************
     * Handles sending a bind-request for an asset, and setting up the asset for status-
     * updates and timeouts.
     ***********************************************************************************/
    synchronized void sendBindRequest(message.BindRequest req, RemoteAsset asset,
                                      TimeSpan timeout=TimeSpan.fromMillis(4000)) {
        req.handle = asset.handle;
        req.timeout = timeout.millis;
        boundAssets[asset.handle] = asset;
        sendMessage(req);
        asset.statusTimeout = timeouts.registerIn(timeout, &asset.triggerTimeout);
    }
    bool closed() {
        return connection.closed;
    }

    void process(Connection c, message.Type type, ubyte[] msg) {
        try {
            with (message) switch (type) {
            case Type.HandShake:
                throw new Connection.InvalidMessage("Handshake not allowed after initialization");
            case Type.BindRead: processBindRead(c, msg); break;
            case Type.BindWrite: processBindWrite(c, msg); break;
            case Type.AssetStatus: processAssetStatus(c, msg); break;
            case Type.ReadRequest: processReadRequest(c, msg); break;
            case Type.ReadResponse: processReadResponse(c, msg); break;
            case Type.DataSegment: processDataSegment(c, msg); break;
            default: throw new Connection.InvalidMessage;
            }
        } catch (Connection.InvalidMessage exc) {
            log.warn("Exception in processing Message: {}", exc);
        }
    }

    /************************************************************************************
     * Real open-function, but should only be used internally by bithorde.
     ***********************************************************************************/
    void open(message.Identifier[] ids, BHAssetStatusCallback cb,
              ulong uuid, TimeSpan timeout, bool singleShotStatus) {
        auto req = new message.BindRead;
        req.ids = ids;
        req.uuid = uuid;
        auto asset = new RemoteAsset(this, req, cb, singleShotStatus);
        sendBindRequest(req, asset, timeout);
    }

    /************************************************************************************
     * Cleanup after a closed RemoteAsset
     ***********************************************************************************/
    protected void onAssetClosed(RemoteAsset asset) {
        freeAssetHandles.push(asset.handle);
    }

    /************************************************************************************
     * Allocates an unused file handle for the transaction.
     ***********************************************************************************/
    protected ushort allocateFreeHandle()
    {
        if (freeAssetHandles.size > 0) {
            return freeAssetHandles.pop();
        } else {
            if (nextNewHandle >= boundAssets.length)
                boundAssets.length = boundAssets.length + 16;
            return nextNewHandle++;
        }
    }

    synchronized void processAssetStatus(Connection c, ubyte[] buf) {
        scope resp = new message.AssetStatus;
        resp.decode(buf);
        log.trace("Recieved AssetStatus for handle {}", resp.handle);
        auto asset = (boundAssets.length>resp.handle)?boundAssets[resp.handle]:null;
        assert(asset, "Got AssetStatus for unknown handle");
        asset.updateStatus(resp);
    }
    synchronized void processReadResponse(Connection c, ubyte[] buf) {
        scope resp = new message.ReadResponse;
        resp.decode(buf);
        try {
            auto req = cast(RemoteAsset.ReadRequest)c.releaseRequest(resp);
            assert(req, "ReadResponse, but not ReadRequest");
            req.callback(resp.status, resp);
        } catch (Connection.InvalidResponse exc) {
            log.warn("Recieved invalid response; {}", resp);
        }
    }
    void processBindRead(Connection c, ubyte[] buf) {
        throw new AssertException("Danger Danger! This client should not get requests!", __FILE__, __LINE__);
    }
    void processReadRequest(Connection c, ubyte[] buf) {
        throw new AssertException("Danger Danger! This client should not get requests!", __FILE__, __LINE__);
    }
    void processBindWrite(Connection c, ubyte[] buf) {
        throw new AssertException("Danger Danger! This client should not get requests!", __FILE__, __LINE__);
    }
    void processDataSegment(Connection c, ubyte[] buf) {
        throw new AssertException("Danger Danger! This client should not get segment data!", __FILE__, __LINE__);
    }
}

/****************************************************************************************
 * Client with standalone pump() and run()-mechanisms. Appropriate for most client-
 * applications.
 ***************************************************************************************/
class SimpleClient : Client {
private:
    Selector selector;
public:
    /************************************************************************************
     * Create client by name, and connect to given address.
     *
     * The SimpleClient is driven by the application in some manner, either by
     * continually calling pump(), or yielding to run(), which will run the client until
     * it is closed.
     ***********************************************************************************/
    this (Address addr, char[] name)
    {
        super(addr, name);
    }

    /************************************************************************************
     * Intercept new connection and create Selector for it
     ***********************************************************************************/
    protected Socket connect(Address addr) {
        auto retval = super.connect(addr);
        selector = new Selector();
        selector.open(1,1);
        selector.register(retval, Event.Read|Event.Error);
        return retval;
    }

    /************************************************************************************
     * Handle remote-side-initiated disconnect. Can be supplemented/overridden in
     * subclasses.
     ***********************************************************************************/
    protected void onDisconnected() {
        close();
    }

    /************************************************************************************
     * Run exactly one cycle of readNewData, processMessage*, processTimeouts
     ***********************************************************************************/
    synchronized void pump() {
        auto timeout = nextDeadline - Clock.now;
        if (selector.select(timeout) > 0) {
            foreach (key; selector.selectedSet())
                process(key);
        }
        processTimeouts(Clock.now);
    }

    /************************************************************************************
     * Process a single SelectionKey event
     ***********************************************************************************/
    void process(ref SelectionKey key) {
        if (key.isReadable) {
            auto read = connection.readNewData();
            if (read) {
                while (connection.processMessage()) {}
            } else {
                onDisconnected();
            }
        } else if (key.isError || key.isHangup) {
            onDisconnected();
        }
    }

    /************************************************************************************
     * Run until closed. Assumes that the calling application is completely event-driven,
     * by the callbacks triggered when recieving responses from BitHorde (or on
     * timeout:s).
     ***********************************************************************************/
    void run() {
        while (!closed)
            pump();
    }
}
