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

class Request {
private:
    Client client;
    ushort id;
public:
    this(Client c, ushort id) {
        this.client = c;
        this.id = id;
    }
}

class OpenRequest : Request {
    this(Client c, ushort id){
        super(c,id);
    }
    void callback(IAsset asset, BHStatus status) {
        scope auto resp = client.createResponse(id, BitHordeMessage.Type.OpenResponse);
        resp.status = status;
        switch (status) {
        case BHStatus.SUCCESS:
            auto handle = 0; // FIXME: need to really allocate free handle
            client.openAssets[handle] = asset;
            resp.handle = handle;
            resp.distance = 1;
            resp.size = asset.size;
            break;
        case BHStatus.NOTFOUND:
            break;
        }
        client.sendMessage(resp);
    }
}

class ReadRequest : Request {
    this(Client c, ushort id){
        super(c,id);
    }
    void callback(IAsset asset, ulong offset, ubyte[] content, BHStatus status) {
        scope auto resp = client.createResponse(id, BitHordeMessage.Type.ReadResponse);
        resp.content = content;
        resp.status = status;
        resp.offset = offset;
        client.sendMessage(resp);
    }
}

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
    BitHordeMessage createResponse(ushort id, BitHordeMessage.Type type)
    {
        auto resp = new BitHordeMessage;
        resp.type = type;
        resp.id = id;
        return resp;
    }

    void processOpenRequest(BitHordeMessage req)
    {
        Stdout("Got open request, ");
        auto r = new OpenRequest(this, req.id);
        try {
            auto asset = cacheMgr.getAsset(cast(BitHordeMessage.HashType)req.hashtype, req.content);
            Stdout("serving from cache").newline;
            r.callback(asset, BHStatus.SUCCESS);
        } catch (IOException e) {
            Stdout("forwarding...").newline;
            server.forwardOpenRequest(cast(BitHordeMessage.HashType)req.hashtype, req.content, req.priority, &r.callback, this);
        }
    }

    void processReadRequest(BitHordeMessage req)
    {
        IAsset asset;
        try {
            asset = openAssets[req.handle];
        } catch (ArrayBoundsException e) {
            auto resp = createResponse(req.id, BitHordeMessage.Type.ReadResponse);
            resp.status = BHStatus.INVALID_HANDLE;
            return sendMessage(resp);
        }
        auto r = new ReadRequest(this, req.id);
        asset.aSyncRead(req.offset, req.size, &r.callback);
    }
}