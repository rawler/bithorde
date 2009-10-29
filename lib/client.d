module lib.client;

private import tango.core.Exception;
private import tango.io.Stdout;
private import tango.math.random.Random;
private import tango.net.SocketConduit;
private import tango.core.Variant;

public import lib.asset;
import lib.connection;
import lib.protobuf;

char[] bytesToHex(ubyte[] bytes) {
    static char[] hex = "0123456789abcdef";
    char[] retval = new char[bytes.length * 2];
    foreach (idx, b; bytes) {
        retval[2*idx]   = hex[b >> 4];
        retval[2*idx+1] = hex[b & 0b00001111];
    }
    return retval;
}

ubyte[] hexToBytes(char[] hex, ubyte[] buf = null) {
    if (!buf)
        buf = new ubyte[hex.length / 2];
    assert(buf.length*2 >= hex.length);
    ubyte[] retval = buf[0..hex.length/2];
    ubyte parseChar(uint idx) {
        auto c = hex[idx];
        if (('0' <= c) && (c <= '9'))
            return cast(ubyte)(c-'0');
        else if (('a' <= c) && (c <= 'f'))
            return cast(ubyte)(c-'a'+10);
        else if (('A' <= c) && (c <= 'F'))
            return cast(ubyte)(c-'A'+10);
        else
            throw new IllegalArgumentException("Argument is not hex at pos: " ~ ItoA(idx));
    }
    foreach (idx, ref b; retval) {
        b = (parseChar(2*idx) << 4) | parseChar(2*idx+1);
    }
    return retval;
}

class RemoteAsset : private message.OpenResponse, IAsset {
private:
    Client client;

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
        auto req = new message.Close;
        req.handle = handle;
        client.sendMessage(req);
        client.openAssets.remove(handle);
    }
public:
    void aSyncRead(ulong offset, uint size, BHReadCallback readCallback) {
        auto req = new message.ReadRequest;
        req.handle = handle;
        req.offset = offset;
        req.size = size;
        req.callback = readCallback;
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
    final message.HashType hashType() { return openRequest.hashType; }
    final AssetId id() { return openRequest.assetId; }

protected:
    void doCallback() {
        (cast(message.OpenOrUploadRequest)request).callback(this, status);
    }
}

class Client : Connection {
private:
    RemoteAsset[uint] openAssets;
public:
    this (SocketConduit s, char[] name)
    {
        super(s, name);
    }
    ~this ()
    {
        foreach (asset; openAssets)
            delete asset;
    }
    void open(message.HashType type, ubyte[] id,
              BHOpenCallback openCallback) {
        open(type, id, openCallback, rand.uniformR2!(ulong)(1,ulong.max));
    }
    void beginUpload(ulong size, BHOpenCallback cb) {
        auto req = new message.UploadRequest;
        req.size = size;
        req.callback = cb;
        sendRequest(req);
    }
package:
    void open(message.HashType type, ubyte[] id, BHOpenCallback openCallback, ulong uuid) {
        auto req = new message.OpenRequest;
        req.hashType = type;
        req.assetId = id;
        req.uuid = uuid;
        req.callback = openCallback;
        sendRequest(req);
    }
protected:
    synchronized void processOpenResponse(ubyte[] buf) {
        auto resp = new RemoteAsset(this);
        resp.decode(buf);
        releaseRequest(resp);
        if (resp.status == message.Status.SUCCESS)
            openAssets[resp.handle] = resp;
        resp.doCallback();
    }
    synchronized void processReadResponse(ubyte[] buf) {
        scope auto resp = new message.ReadResponse;
        resp.decode(buf);
        auto req = cast(message.ReadRequest)releaseRequest(resp);
        req.callback(openAssets[req.handle], resp.offset, resp.content, resp.status);
    }
    void processOpenRequest(ubyte[] buf) {
        Stdout("Danger Danger! This client should not get requests!").newline;
    }
    void processClose(ubyte[] buf) {
        Stdout("Danger Danger! This client should not get requests!").newline;
    }
    void processReadRequest(ubyte[] buf) {
        Stdout("Danger Danger! This client should not get requests!").newline;
    }
    void processUploadRequest(ubyte[] buf) {
        Stdout("Danger Danger! This client should not get requests!").newline;
    }
    void processDataSegment(ubyte[] buf) {
        Stdout("Danger Danger! This client should not get segment data!").newline;
    }
}