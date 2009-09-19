module lib.client;

private import tango.core.Exception;
private import tango.io.Stdout;
private import tango.net.SocketConduit;
private import tango.core.Variant;

import lib.asset;
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
alias void delegate(RemoteAsset, BitHordeMessage) BHOpenCallback;
alias void delegate(RemoteAsset, ulong offset, ubyte[], BitHordeMessage) BHReadCallback;

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
        auto reqData = new BHOpenRequest;
        reqData.decode(req.content);
        this.hType = cast(BitHordeMessage.HashType)reqData.hash;
        this.id = reqData.id.dup;
        auto respData = new BHOpenResponse;
        respData.decode(resp.content);
        this.handle = respData.handle;
        this.distance = respData.distance;
        this._size = respData.size;
    }
public:
    ubyte[] read(ulong offset, uint size) {
        return []; // FIXME: Funkar inte för asynkrona anrop. :S
    }

    void aSyncRead(ulong offset, uint size, BHReadCallback readCallback) {
        auto r = new BHReadRequest;
        r.handle = handle;
        r.offset = offset;
        r.size = size;
        client._request(BitHordeMessage.Type.ReadRequest, r, Variant(readCallback));
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
    void open(BitHordeMessage.HashType type, ubyte[] id, BHOpenCallback openCallback) {
        auto r = new BHOpenRequest;
        r.priority = 128;
        r.hash = type;
        r.id = id;
        _request(BitHordeMessage.Type.OpenRequest, r, Variant(openCallback));
    }
protected:
    void processResponse(BitHordeMessage req, BitHordeMessage response) {
        scope (exit) callbacks.remove(req.id);
        switch (response.type) {
        case BitHordeMessage.Type.OpenResponse:
            auto asset = new RemoteAsset(this, req, response);
            openAssets[asset.handle] = asset;
            callbacks[req.id].get!(BHOpenCallback)()(asset, response);
            break;
        case BitHordeMessage.Type.ReadResponse:
            auto reqData = new BHReadRequest;
            reqData.decode(req.content);
            auto respData = new BHReadResponse;
            respData.decode(response.content);
            callbacks[req.id].get!(BHReadCallback)()(openAssets[reqData.handle], respData.offset, respData.content, response);
            break;
        default:
            Stdout("Unknown response");
        }
    }
    void processRequest(BitHordeMessage req) {
        Stdout("Danger Danger! This client should not get requests!").newline;
    }
private:
    void _request(BitHordeMessage.Type type, ProtoBufMessage content, Variant callback) {
        auto req = allocRequest(type, content);
        callbacks[req.id] = callback;
        sendMessage(req);
    }
}