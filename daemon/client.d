module daemon.client;

private import tango.core.Exception;
private import tango.core.Memory;
private import tango.io.Stdout;
private import tango.math.random.Random;
private import tango.net.SocketConduit;
private import tango.util.container.more.Stack;

import daemon.server;
import daemon.cache;
import lib.asset;
import lib.client;
import message = lib.message;
import lib.protobuf;

alias void delegate(IServerAsset, message.Status status) BHServerOpenCallback;

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
    final void callback(IServerAsset asset, message.Status status) {
        if (client) {
            scope auto resp = new message.OpenResponse;
            resp.rpcId = id;
            resp.status = status;
            switch (status) {
            case message.Status.SUCCESS:
                auto handle = client.allocateFreeHandle;
                client.openAssets[handle] = asset;
                resp.handle = handle;
                resp.size = asset.size;
                break;
            case message.Status.NOTFOUND:
                break;
            case message.Status.WOULD_LOOP:
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
    final void callback(IAsset asset, ulong offset, ubyte[] content, message.Status status) {
        if (client) {
            scope auto resp = new message.ReadResponse;
            resp.rpcId = id;
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
        this.server = server;
        this.cacheMgr = server.cacheMgr;
        super(s, server.name);
    }
    ~this()
    {
        foreach (asset; openAssets)
            asset.unRef();
        foreach (req; inFlightRequests)
            req.client = null; // Make sure stale requests know we're gone
    }
protected:
    void process(message.OpenRequest req)
    {
        Stdout("Got open request, ");
        auto r = new OpenRequest(this, req.rpcId);
        ulong reqid = req.session;
        if (reqid == 0)
            reqid = rand.uniformR2!(ulong)(1,ulong.max);
        server.getAsset(req.hashType, req.assetId, reqid, &r.callback, this);
    }

    void process(message.ReadRequest req)
    {
        IAsset asset;
        try {
            asset = openAssets[req.handle];
        } catch (ArrayBoundsException e) {
            scope auto resp = new message.ReadResponse;
            resp.rpcId = req.rpcId;
            resp.status = message.Status.INVALID_HANDLE;
            return sendMessage(resp);
        }
        auto r = new ReadRequest(this, req.rpcId);
        asset.aSyncRead(req.offset, req.size, &r.callback);
    }

    void process(message.Close req)
    {
        Stderr.format("Client {} closing handle {}: ", this, req.handle);
        try {
            IServerAsset asset = openAssets[req.handle];
            openAssets.remove(req.handle);
            freeFileHandles.push(req.handle);
            asset.unRef();
        } catch (ArrayBoundsException e) {
            Stderr("[INVALID_HANDLE]").newline;
            return;
        }
        Stderr("[OK]").newline;
    }
private:
    ushort allocateFreeHandle()
    {
        if (freeFileHandles.size > 0)
            return freeFileHandles.pop();
        else
            return nextNewHandle++;
    }
}