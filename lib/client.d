module lib.client;

private import tango.core.Exception;
private import tango.io.Stdout;
private import tango.net.SocketConduit;

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

class Client : Connection {
private:
    void delegate(BitHordeMessage)[uint] callbacks;
public:
    this (SocketConduit s)
    {
        super(s);
    }
    void open(BitHordeMessage.HashType type, ubyte[] id, void delegate(BitHordeMessage) callback) {
        auto r = new BHOpenRequest;
        r.priority = 128;
        r.hash = type;
        r.id = id;
        _request(BitHordeMessage.Type.OpenRequest, r, callback);
    }
    void readData(uint handle, ulong offset, uint size, void delegate(BitHordeMessage) callback) {
        auto r = new BHReadRequest;
        r.handle = handle;
        r.offset = offset;
        r.size = size;
        _request(BitHordeMessage.Type.ReadRequest, r, callback);
    }
protected:
    void processResponse(BitHordeMessage req, BitHordeMessage response) {
        scope (exit) callbacks.remove(req.id);
        callbacks[req.id](response);
    }
    void processRequest(BitHordeMessage req) {
        Stdout("Danger Danger! This client should not get requests!").newline;
    }
private:
    void _request(BitHordeMessage.Type type, ProtoBufMessage content, void delegate(BitHordeMessage) callback) {
        auto req = allocRequest(type, content);
        callbacks[req.id] = callback;
        sendMessage(req);
    }
}