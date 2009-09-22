module lib.client;

private import tango.core.Exception;
private import tango.io.Stdout;
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

ubyte[] hexToBytes(char[] hex) {
    ubyte[] retval = new ubyte[hex.length / 2];
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

alias void delegate(BitHordeMessage) BHMessageCallback;
class RemoteAsset : IAsset {
private:
    Client client;
    BitHordeMessage.HashType hType;
    ubyte[] id;
    uint handle;
    ubyte distance;
    ulong _size;
protected:
    this(Client c, BitHordeMessage req, BitHordeMessage resp) {
        this.client = c;
        this.hType = cast(BitHordeMessage.HashType)req.hashtype;
        this.id = req.content.dup;
        this.handle = resp.handle;
        this.distance = resp.distance;
        this._size = resp.size;
    }

    ~this() {
        auto req = client.allocRequest(BitHordeMessage.Type.CloseRequest);
        req.handle = handle;
        client._sendRequest(req, Variant(null));
        client.openAssets.remove(handle);
    }
public:
    void aSyncRead(ulong offset, uint size, BHReadCallback readCallback) {
        auto req = client.allocRequest(BitHordeMessage.Type.ReadRequest);
        req.handle = handle;
        req.offset = offset;
        req.size = size;
        client._sendRequest(req, Variant(readCallback));
    }

    ulong size() {
        return _size;
    }
}

class Client : Connection {
private:
    Variant[uint] callbacks;
    RemoteAsset[uint] openAssets;
public:
    this (SocketConduit s)
    {
        super(s);
    }
    ~this ()
    {
        foreach (asset; openAssets)
            delete asset;
    }
    void open(BitHordeMessage.HashType type, ubyte[] id, BHOpenCallback openCallback) {
        auto req = allocRequest(BitHordeMessage.Type.OpenRequest);
        req.priority = 128;
        req.hashtype = type;
        req.content = id;
        _sendRequest(req, Variant(openCallback));
    }
protected:
    void processResponse(BitHordeMessage req, BitHordeMessage resp) {
        scope (exit) callbacks.remove(req.id);
        switch (req.type) {
        case BitHordeMessage.Type.OpenRequest:
            RemoteAsset asset;
            if (cast(BHStatus)resp.status == BHStatus.SUCCESS) {
                asset = new RemoteAsset(this, req, resp);
                openAssets[asset.handle] = asset;
            }
            callbacks[req.id].get!(BHOpenCallback)()(asset, cast(BHStatus)resp.status);
            break;
        case BitHordeMessage.Type.ReadRequest:
            callbacks[req.id].get!(BHReadCallback)()(openAssets[req.handle], resp.offset, resp.content, cast(BHStatus)resp.status);
            break;
        case BitHordeMessage.Type.CloseRequest: // CloseRequests returns nothing
            break;
        default:
            Stdout("Unknown response");
        }
    }
    void processRequest(BitHordeMessage req) {
        Stdout("Danger Danger! This client should not get requests!").newline;
    }
private:
    void _sendRequest(BitHordeMessage req, Variant callback) {
        callbacks[req.id] = callback;
        sendMessage(req);
    }
}