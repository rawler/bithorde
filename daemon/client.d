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
    BitHordeMessage createResponse(BitHordeMessage req, BitHordeMessage.Type type)
    {
        auto resp = new BitHordeMessage;
        resp.type = type;
        resp.id = req.id;
        return resp;
    }

    void processOpenRequest(BitHordeMessage req)
    {
        auto asset = cacheMgr.getAsset(cast(BitHordeMessage.HashType)req.hashtype, req.content);
        auto handle = 0; // FIXME: need to really allocate free handle
        openAssets[handle] = asset;
        scope auto resp = createResponse(req, BitHordeMessage.Type.OpenResponse);
        resp.handle = handle;
        resp.distance = 1;
        resp.size = asset.size;
        sendMessage(resp);
    }

    void processReadRequest(BitHordeMessage req)
    {
        auto asset = openAssets[req.handle];
        scope auto resp = createResponse(req, BitHordeMessage.Type.ReadResponse);
        resp.offset = req.offset;
        asset.aSyncRead(req.offset, req.size,
            delegate void(IAsset asset, ulong offset, ubyte[] content, BHStatusCode status) {
                resp.content = content;
        });
        sendMessage(resp);
    }
}