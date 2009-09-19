module daemon.client;

private import tango.core.Exception;
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
        scope auto resp = createResponse(req, BitHordeMessage.Type.OpenResponse);
        try {
            auto asset = cacheMgr.getAsset(cast(BitHordeMessage.HashType)req.hashtype, req.content);
            auto handle = 0; // FIXME: need to really allocate free handle
            openAssets[handle] = asset;
            resp.handle = handle;
            resp.distance = 1;
            resp.size = asset.size;
            resp.status = BHStatus.SUCCESS;
        } catch (IOException e) {
            resp.status = BHStatus.NOTFOUND;
        }
        sendMessage(resp);
    }

    void processReadRequest(BitHordeMessage req)
    {
        scope auto resp = createResponse(req, BitHordeMessage.Type.ReadResponse);
        try {
            auto asset = openAssets[req.handle];
            resp.status = BHStatus.SUCCESS;
            resp.offset = req.offset;
            asset.aSyncRead(req.offset, req.size,
                delegate void(IAsset asset, ulong offset, ubyte[] content, BHStatus status) {
                    resp.content = content;
            });
        } catch (ArrayBoundsException e) {
            resp.status = BHStatus.INVALID_HANDLE;
        }
        sendMessage(resp);
    }
}