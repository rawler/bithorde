module daemon.client;

private import tango.io.Stdout;
private import tango.net.SocketConduit;

import daemon.server;
import daemon.cache;
import lib.asset;
import lib.client;
import lib.message;
import lib.protobuf;

class Client : lib.client.Client {
private:
    Server server;
    CacheManager cacheMgr;
    IAsset[uint] openAssets;
public:
    this (Server server, SocketConduit s)
    {
        super(s);
        this.server = server;
        this.cacheMgr = server.cacheMgr;
    }
protected:
    void processRequest(BitHordeMessage req) {
        switch (req.type) {
            case BitHordeMessage.Type.OpenRequest: processOpenRequest(req); break;
            case BitHordeMessage.Type.ReadRequest: processReadRequest(req); break;
            default:
                Stdout.format("Unknown request type: {}", req.type);
        }
    }
private:
    void sendResponse(BitHordeMessage req, BitHordeMessage.Type type, ProtoBufMessage content)
    {
        scope auto resp = new BitHordeMessage;
        resp.type = type;
        resp.id = req.id;
        resp.content = content.encode();
        sendMessage(resp);
    }

    void processOpenRequest(BitHordeMessage req)
    {
        Stdout("Got open Request").newline;
        auto reqData = new BHOpenRequest;
        reqData.decode(req.content);
        auto asset = cacheMgr.getAsset(cast(BitHordeMessage.HashType)reqData.hash, reqData.id);
        auto handle = 0; // FIXME: need to really allocate free handle
        openAssets[handle] = asset;
        auto respData = new BHOpenResponse;
        respData.handle = handle;
        respData.distance = 1;
        respData.size = asset.size;
        sendResponse(req, BitHordeMessage.Type.OpenResponse, respData);
    }

    void processReadRequest(BitHordeMessage req)
    {
        Stdout("Got read Request").newline;
        auto reqData = new BHReadRequest;
        reqData.decode(req.content);
        auto asset = openAssets[reqData.handle];
        auto respData = new BHReadResponse;
        respData.offset = reqData.offset;
        respData.content = asset.read(reqData.offset, reqData.size);
        sendResponse(req, BitHordeMessage.Type.ReadResponse, respData);
    }
}