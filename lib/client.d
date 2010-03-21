module lib.client;

private import tango.core.Exception;
private import tango.math.random.Random;
private import tango.net.device.Socket;
private import tango.time.Time;

public import lib.asset;
import lib.connection;
import lib.protobuf;

class RemoteAsset : private message.OpenResponse, IAsset {
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
    this(Client c) {
        this.client = c;
    }
    ~this() {
        if (!closed)
            close();
    }
public:
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

class Client : Connection {
private:
    class UploadRequest : message.UploadRequest {
        BHOpenCallback callback;
        this(BHOpenCallback cb) {
            this.callback = cb;
        }
        void abort(message.Status s) {
            callback(null, s, this, null);
        }
    }
    class OpenRequest : message.OpenRequest {
        BHOpenCallback callback;
        this(BHOpenCallback cb) {
            this.callback = cb;
        }
        void abort(message.Status s) {
            callback(null, s, this, null);
        }
    }
    RemoteAsset[uint] openAssets;
public:
    this (Socket s, char[] name)
    {
        super(s, name);
    }
    this (Address addr, char[] name)
    {
        auto socket = new Socket(addr.addressFamily, SocketType.STREAM, ProtocolType.IP);
        socket.connect(addr);
        this(socket, name);
    }
    ~this ()
    {
        foreach (asset; openAssets)
            delete asset;
    }
    void open(message.Identifier[] ids,
              BHOpenCallback openCallback, TimeSpan timeout = TimeSpan.fromMillis(500)) {
        open(ids, openCallback, rand.uniformR2!(ulong)(1,ulong.max), timeout);
    }

    void beginUpload(ulong size, BHOpenCallback cb) {
        auto req = new UploadRequest(cb);
        req.size = size;
        sendRequest(req);
    }
package:
    void open(message.Identifier[] ids, BHOpenCallback openCallback, ulong uuid, TimeSpan timeout) {
        auto req = new OpenRequest(openCallback);
        req.ids = ids;
        req.uuid = uuid;
        sendRequest(req, timeout);
    }
protected:
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
