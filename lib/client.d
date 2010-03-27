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
private import tango.math.random.Random;
private import tango.net.device.Socket;
private import tango.time.Time;
private import tango.util.log.Log;

public import lib.asset;
import lib.connection;
import lib.protobuf;

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
        this(BHReadCallback cb) {
            this.handle = this.outer.handle;
            _callback = cb;
        }
        void callback(message.ReadResponse resp) {
            _callback(this.outer, resp.status, this, resp);
        }
        void abort(message.Status s) {
            _callback(this.outer, s, this, null);
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

    void aSyncRead(ulong offset, uint size, BHReadCallback readCallback) {
        auto req = new ReadRequest(readCallback);
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
        auto req = new message.Close;
        req.handle = handle;
        if (!client.closed)
            client.sendMessage(req);
        client.openAssets.remove(handle);
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
 * The Client also needs to be driven by the application in some manner, either by
 * continually calling pump(), or yielding to run(), which will run the client until
 * it is closed.
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
        auto socket = new Socket(addr.addressFamily, SocketType.STREAM, ProtocolType.IP);
        socket.connect(addr);
        this(socket, name);
    }
    this (Socket s, char[] name) {
        this.log = Log.lookup("lib.client");
        super(s, name);
        this.log = Log.lookup("daemon.client."~peername);
    }

    ~this ()
    {
        foreach (asset; openAssets)
            asset.close();
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

    /************************************************************************************
     * Run until closed. Assumes that the calling application is event-driven, by the
     * callbacks triggerd when recieving responses from BitHorde (or on timeout:s).
     ***********************************************************************************/
    void run() {
        while (!closed)
            pump();
    }
protected:
    void process(message.Type type, ubyte[] msg) {
        try {
            super.process(type, msg);
        } catch (InvalidMessage exc) {
            log.warn(exc.toString);
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
        req.callback(resp);
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
