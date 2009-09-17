module lib.client;

private import tango.io.Stdout;
private import tango.net.SocketConduit;

import lib.connection;
import lib.protobuf;

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