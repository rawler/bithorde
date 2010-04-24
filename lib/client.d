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
private import tango.time.Time;
private import tango.util.log.Log;

public import lib.asset;
import lib.connection;
import lib.protobuf;

alias void delegate(Object) DEvent;
extern (C) void rt_attachDisposeEvent(Object h, DEvent e);

/****************************************************************************************
 * RemoteAsset is the basic BitHorde object for tracking a remotely open asset form the
 * client-side.
 ***************************************************************************************/
class RemoteAsset : private message.OpenResponse, IAsset {
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
                client.sendRequest(this);
            } else {
                _callback(this.outer, s, this, resp);
            }
        }
        void abort(message.Status s) {
            callback(s, null);
        }
    }
    /************************************************************************************
     * Internal MetaDataRequest object, for tracking in-flight readrequests.
     ***********************************************************************************/
    class MetaDataRequest : message.MetaDataRequest {
        BHMetaDataCallback _callback;
        this(BHMetaDataCallback cb) {
            this.handle = this.outer.handle;
            _callback = cb;
        }
        void callback(message.MetaDataResponse resp) {
            _callback(this.outer, resp.status, this, resp);
        }
        void abort(message.Status s) {
            _callback(this.outer, s, this, null);
        }
    }
private:
    Client client;
    bool closed;
    void clientGone(Object o) {
        this.client = null;
    }

    message.OpenRequest _req;
    final message.OpenRequest openRequest() {
        if (!_req)
            return _req = cast(message.OpenRequest)request;
        else
            return _req;
    }
protected:
    /************************************************************************************
     * RemoteAssets should only be created from the Client
     ***********************************************************************************/
    this(Client c) {
        rt_attachDisposeEvent(c, &clientGone); // Add hook for invalidating client-reference
        this.client = c;
    }
    ~this() {
        if (!closed)
            close();
    }
public:
    ushort handle() {
        return message.OpenResponse.handle;
    }
    message.Identifier[] requestIds() {
        return openRequest.ids;
    }

    /************************************************************************************
     * aSyncRead as of IAsset. With or without explicit retry-count
     ***********************************************************************************/
    void aSyncRead(ulong offset, uint size, BHReadCallback readCallback) {
        aSyncRead(offset, size, readCallback, 5);
    }
    void aSyncRead(ulong offset, uint size, BHReadCallback readCallback, ushort retries) { /// ditto
        auto req = new ReadRequest(readCallback, retries);
        req.offset = offset;
        req.size = size;
        client.sendRequest(req);
    }

    void requestMetaData(BHMetaDataCallback cb) {
        auto req = new MetaDataRequest(cb);
        client.sendRequest(req);
    }

    void sendDataSegment(ulong offset, ubyte[] data) {
        auto msg = new message.DataSegment;
        msg.handle = handle;
        msg.offset = offset;
        msg.content = data;
        client.sendMessage(msg);
    }

    final ulong size() {
        return super.size;
    }

    void close() {
        closed = true;
        if (client) {
            if (!client.closed) {
                scope req = new message.Close;
                req.handle = handle;
                client.sendMessage(req);
            }
            client.openAssets.remove(handle);
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
class Client : Connection {
private:
    /************************************************************************************
     * Internal outgoing UploadRequest object
     ***********************************************************************************/
    class UploadRequest : message.UploadRequest {
        BHOpenCallback callback;
        this(BHOpenCallback cb) {
            this.callback = cb;
        }
        void abort(message.Status s) {
            callback(null, s, this, null);
        }
    }

    /************************************************************************************
     * Internal outgoing OpenRequest object
     ***********************************************************************************/
    class OpenRequest : message.OpenRequest {
        BHOpenCallback callback;
        this(BHOpenCallback cb) {
            this.callback = cb;
        }
        void abort(message.Status s) {
            callback(null, s, this, null);
        }
    }
private:
    RemoteAsset[uint] openAssets;
    protected Logger log;
public:
    /************************************************************************************
     * Create a BitHorde client by name and an IPv4Address, or a LocalAddress.
     ***********************************************************************************/
    this (Address addr, char[] name)
    {
        super(name);
        connect(addr);
    }

    /************************************************************************************
     * Create BitHorde client on provided Socket
     ***********************************************************************************/
    this (Socket s, char[] name) {
        this.log = Log.lookup("lib.client");
        super(name);
        handshake(s);
        this.log = Log.lookup("daemon.client."~peername);
    }

    /************************************************************************************
     * Connect to specified address
     ***********************************************************************************/
    protected Socket connect(Address addr) {
        auto socket = new Socket(addr.addressFamily, SocketType.STREAM, ProtocolType.IP);
        socket.connect(addr);
        handshake(socket);
        return socket;
    }

    void close()
    {
        auto assets = openAssets.values;
        foreach (asset; assets)
            asset.close();
        super.close();
    }

    /************************************************************************************
     * Attempt to open an asset identified by any of a set of ids.
     *
     * Params:
     *     ids           =  A list of ids to match. Priorities, and outcome of conflicts
     *                      in ID:s are undefined
     *     openCallback  =  A callback to be notified when the open request has completed
     *     timeout       =  (optional) How long to wait before automatically failing the
     *                      request. Defaults to 500msec.
     ***********************************************************************************/
    void open(message.Identifier[] ids,
              BHOpenCallback openCallback, TimeSpan timeout = TimeSpan.fromMillis(3000)) {
        open(ids, openCallback, rand.uniformR2!(ulong)(1,ulong.max), timeout);
    }

    /************************************************************************************
     * Create a new remote asset for uploading
     ***********************************************************************************/
    void beginUpload(ulong size, BHOpenCallback cb) {
        auto req = new UploadRequest(cb);
        req.size = size;
        sendRequest(req);
    }
protected:
    void process(message.Type type, ubyte[] msg) {
        try {
            super.process(type, msg);
        } catch (InvalidMessage exc) {
            log.warn("Exception in processing Message: {}", exc);
        }
    }

    /************************************************************************************
     * Real open-function, but should only be used internally by bithorde.
     ***********************************************************************************/
    void open(message.Identifier[] ids, BHOpenCallback openCallback, ulong uuid,
              TimeSpan timeout) {
        auto req = new OpenRequest(openCallback);
        req.ids = ids;
        req.uuid = uuid;
        req.handle = 0;
        while (req.handle in openAssets) req.handle++; // Find first free handle
        sendRequest(req, timeout);
    }

    synchronized void processOpenResponse(ubyte[] buf) {
        auto resp = new RemoteAsset(this);
        IAsset asset;
        resp.decode(buf);
        if (resp.status == message.Status.SUCCESS) {
            openAssets[resp.handle] = resp;
            asset = resp;
        }
        auto basereq = releaseRequest(resp);
        if (basereq.typeId == message.Type.UploadRequest) {
            auto req = cast(UploadRequest)basereq;
            assert(req, "OpenResponse, but not OpenOrUploadRequest");
            req.callback(asset, resp.status, req, resp);
        } else if (basereq.typeId == message.Type.OpenRequest) {
            auto req = cast(OpenRequest)basereq;
            assert(req, "OpenResponse, but not OpenOrUploadRequest");
            req.callback(asset, resp.status, req, resp);
        }
    }
    synchronized void processReadResponse(ubyte[] buf) {
        scope auto resp = new message.ReadResponse;
        resp.decode(buf);
        auto req = cast(RemoteAsset.ReadRequest)releaseRequest(resp);
        assert(req, "ReadResponse, but not MetaDataRequest");
        req.callback(resp.status, resp);
    }
    synchronized void processMetaDataResponse(ubyte[] buf) {
        scope auto resp = new message.MetaDataResponse;
        resp.decode(buf);
        auto req = cast(RemoteAsset.MetaDataRequest)releaseRequest(resp);
        assert(req, "MetaDataResponse, but not MetaDataRequest");
        req.callback(resp);
    }
    void processOpenRequest(ubyte[] buf) {
        throw new AssertException("Danger Danger! This client should not get requests!", __FILE__, __LINE__);
    }
    void processClose(ubyte[] buf) {
        throw new AssertException("Danger Danger! This client should not get requests!", __FILE__, __LINE__);
    }
    void processReadRequest(ubyte[] buf) {
        throw new AssertException("Danger Danger! This client should not get requests!", __FILE__, __LINE__);
    }
    void processUploadRequest(ubyte[] buf) {
        throw new AssertException("Danger Danger! This client should not get requests!", __FILE__, __LINE__);
    }
    void processDataSegment(ubyte[] buf) {
        throw new AssertException("Danger Danger! This client should not get segment data!", __FILE__, __LINE__);
    }
    void processMetaDataRequest(ubyte[] buf) {
        throw new AssertException("Danger Danger! This client should not get requests!", __FILE__, __LINE__);
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
        if (selector.select(nextTimeOut) > 0) {
            foreach (key; selector.selectedSet()) {
                assert(key.conduit is socket);
                if (key.isReadable) {
                    auto read = readNewData();
                    if (read)
                        while (processMessage()) {}
                    else
                        onDisconnected();
                } else if (key.isError) {
                    onDisconnected();
                }
            }
        }
        processTimeouts();
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
