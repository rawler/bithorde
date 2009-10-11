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

class RemoteAsset : IAsset {
private:
    Client client;
    message.HashType hType;
    ubyte[] id;
    uint handle;
    ubyte distance;
    ulong _size;
protected:
    this(Client c, message.OpenRequest req, message.OpenResponse resp) {
        this.client = c;
        this.hType = cast(message.HashType)req.hashType;
        this.id = req.assetId.dup;
        this.handle = resp.handle;
        this._size = resp.size;
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

    ulong size() {
        return _size;
    }
}

class Client : Connection {
private:
    Variant[100] callbacks;
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
package:
    void open(message.HashType type, ubyte[] id, BHOpenCallback openCallback, ulong sessionid) {
        auto req = new message.OpenRequest;
        req.hashType = type;
        req.assetId = id;
        req.session = sessionid;
        req.callback = openCallback;
        sendRequest(req);
    }
protected:
    synchronized void process(message.OpenResponse resp) {
        auto req = cast(message.OpenRequest)resp.request;
        RemoteAsset asset;
        if (resp.status == message.Status.SUCCESS) {
            asset = new RemoteAsset(this, req, resp);
            openAssets[asset.handle] = asset;
        }
        req.callback(asset, resp.status);
    }
    synchronized void process(message.ReadResponse resp) {
        auto req = cast(message.ReadRequest)resp.request;
        scope (exit) callbacks[req.rpcId].clear;
        req.callback(openAssets[req.handle], resp.offset, resp.content, resp.status);
    }
    void process(message.OpenRequest req) {
        Stdout("Danger Danger! This client should not get requests!").newline;
    }
    void process(message.Close req) {
        Stdout("Danger Danger! This client should not get requests!").newline;
    }
    void process(message.ReadRequest req) {
        Stdout("Danger Danger! This client should not get requests!").newline;
    }
}