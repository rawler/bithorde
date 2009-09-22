module daemon.client;

private import tango.core.Exception;
private import tango.core.Memory;
private import tango.io.Stdout;
private import tango.net.SocketConduit;
private import tango.util.container.more.Stack;

import daemon.server;
import daemon.cache;
import lib.asset;
import lib.client;
import lib.message;
import lib.protobuf;

alias void delegate(IServerAsset, BHStatus status) BHServerOpenCallback;

interface IRefCounted {
    template Impl() {
    private:
        uint refcount;
    public:
        void takeRef() {
            refcount++;
        }
        void unRef() {
            if (--refcount <= 0)
                delete this;
        }
    }
    void takeRef();
    void unRef();
}

interface IServerAsset : IAsset, IRefCounted {}

class Request {
private:
    Client client;
    ushort id;
public:
    this(Client c, ushort id) {
        this.client = c;
        this.id = id;
        c.inFlightRequests[id] = this;
    }
    ~this() {
        if (client)
            client.inFlightRequests.remove(id);
    }
}

class OpenRequest : Request {
    this(Client c, ushort id){
        super(c,id);
    }
    final void callback(IServerAsset asset, BHStatus status) {
        if (client) {
            scope auto resp = client.createResponse(id, BitHordeMessage.Type.OpenResponse);
            resp.status = status;
            switch (status) {
            case BHStatus.SUCCESS:
                auto handle = client.allocateFreeHandle;
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
        delete this;
    }
}

class ReadRequest : Request {
    static ReadRequest _freeList;
    static uint alloc, reuse;
    ReadRequest _next;
    new(size_t sz)
    {
        ReadRequest m;

        if (_freeList) {
            m = _freeList;
            _freeList = m._next;
            reuse++;
        } else {
            m = cast(ReadRequest)GC.malloc(sz);
            alloc++;
        }
        return cast(void*)m;
    }
    delete(void * p)
    {
        auto m = cast(ReadRequest)p;
        m._next = _freeList;
        _freeList = m;
    }
public:
    this(Client c, ushort id){
        super(c,id);
    }
    final void callback(IAsset asset, ulong offset, ubyte[] content, BHStatus status) {
        if (client) {
            scope auto resp = client.createResponse(id, BitHordeMessage.Type.ReadResponse);
            resp.content = content;
            resp.status = status;
            resp.offset = offset;
            client.sendMessage(resp);
        }
        delete this;
    }
}

class Client : lib.client.Client {
private:
    Server server;
    CacheManager cacheMgr;
    IServerAsset[uint] openAssets;
    Request[ushort] inFlightRequests;
    Stack!(ushort, 64) freeFileHandles;
    ushort nextNewHandle;
public:
    this (Server server, SocketConduit s)
    {
        super(s);
        this.server = server;
        this.cacheMgr = server.cacheMgr;
    }
    ~this()
    {
        foreach (asset; openAssets)
            asset.unRef();
        foreach (req; inFlightRequests)
            req.client = null; // Make sure stale requests know we're gone
    }
protected:
    void processRequest(BitHordeMessage req) {
        switch (req.type) {
            case BitHordeMessage.Type.OpenRequest:  processOpenRequest(req); break;
            case BitHordeMessage.Type.ReadRequest:  processReadRequest(req); break;
            case BitHordeMessage.Type.CloseRequest: processCloseRequest(req); break;
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

    ushort allocateFreeHandle()
    {
        if (freeFileHandles.size > 0) {
            Stderr("Was here").newline;
            return freeFileHandles.pop();
        } else {
            Stderr("Here too").newline;
            return nextNewHandle++;
        }
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
            scope auto resp = createResponse(req.id, BitHordeMessage.Type.ReadResponse);
            resp.status = BHStatus.INVALID_HANDLE;
            return sendMessage(resp);
        }
        auto r = new ReadRequest(this, req.id);
        asset.aSyncRead(req.offset, req.size, &r.callback);
    }

    void processCloseRequest(BitHordeMessage req)
    {
        scope auto resp = createResponse(req.id, BitHordeMessage.Type.CloseResponse);
        resp.handle = req.handle;
        Stderr.format("Client {} closing handle {}: ", this, req.handle);
        try {
            IServerAsset asset = openAssets[req.handle];
            openAssets.remove(req.handle);
            freeFileHandles.push(req.handle);
            asset.unRef();
            resp.status = BHStatus.SUCCESS;
        } catch (ArrayBoundsException e) {
            resp.status = BHStatus.INVALID_HANDLE;
            Stderr("[INVALID_HANDLE]").newline;
            return;
        }
        Stderr("[OK]").newline;
        return sendMessage(resp);
    }
}