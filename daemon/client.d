module daemon.client;

private import tango.core.Exception;
private import tango.core.Memory;
private import tango.math.random.Random;
private import tango.net.device.Socket;
private import tango.util.container.more.Stack;
private import tango.util.log.Log;

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
interface IAssetSource {
    IServerAsset findAsset(daemon.client.OpenRequest req);
}

class OpenRequest : message.OpenRequest {
    Client client;
    this(Client c) {
        client = c;
    }
    final void callback(IServerAsset asset, message.Status status) {
        if (client) {
            scope auto resp = new message.OpenResponse;
            resp.rpcId = rpcId;
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

class UploadRequest : message.UploadRequest {
    Client client;
    this(Client c) {
        client = c;
    }
    final void callback(IServerAsset asset, message.Status status) {
        if (client) {
            scope auto resp = new message.OpenResponse;
            resp.rpcId = rpcId;
            resp.status = status;
            switch (status) {
            case message.Status.SUCCESS:
                auto handle = client.allocateFreeHandle;
                client.openAssets[handle] = asset;
                resp.handle = handle;
                break;
            // TODO: And else?
            }
            client.sendMessage(resp);
        }
        delete this;
    }
}

class ReadRequest : message.ReadRequest {
    Client client;
public:
    this(Client c) {
        client = c;
    }
    final void callback(IAsset asset, ulong offset, ubyte[] content, message.Status status) {
        if (client) {
            scope auto resp = new message.ReadResponse;
            resp.rpcId = rpcId;
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
    Stack!(ushort, 64) freeFileHandles;
    ushort nextNewHandle;
    Logger log;
public:
    this (Server server, Socket s)
    {
        this.server = server;
        this.cacheMgr = server.cacheMgr;
        this.log = Log.lookup("daemon.client");
        super(s, server.name);
        this.log = Log.lookup("daemon.client."~_peername);
    }
    ~this()
    {
        foreach (asset; openAssets)
            asset.unRef();
    }
protected:
    void processOpenRequest(ubyte[] buf)
    {
        auto req = new OpenRequest(this);
        req.decode(buf);
        log.trace("Got open request");
        ulong uuid = req.uuid;
        if (uuid == 0)
            uuid = rand.uniformR2!(ulong)(1,ulong.max);
        server.findAsset(req);
    }

    void processUploadRequest(ubyte[] buf)
    {
        if (!isTrusted) {
            log.warn("Got UploadRequest from unauthorized client {}", this);
            return;
        }
        auto req = new UploadRequest(this);
        req.decode(buf);
        log.trace("Got UploadRequest from trusted client");
        server.uploadAsset(req);
    }

    void processReadRequest(ubyte[] buf)
    {
        auto req = new ReadRequest(this);
        req.decode(buf);
        IAsset asset;
        try {
            asset = openAssets[req.handle];
        } catch (ArrayBoundsException e) {
            delete req;
            scope auto resp = new message.ReadResponse;
            resp.rpcId = req.rpcId;
            resp.status = message.Status.INVALID_HANDLE;
            return sendMessage(resp);
        }
        asset.aSyncRead(req.offset, req.size, &req.callback);
    }

    void processDataSegment(ubyte[] buf) {
        scope auto req = new message.DataSegment();
        req.decode(buf);
        try {
            auto asset = cast(CachedAsset)openAssets[req.handle];
            asset.add(req.offset, req.content);
        } catch (ArrayBoundsException e) {
            log.error("DataSegment to invalid handle");
        }
    }

    void processMetaDataRequest(ubyte[] buf) {
        scope auto req = new message.MetaDataRequest();
        req.decode(buf);
        scope auto resp = new message.MetaDataResponse;
        resp.rpcId = req.rpcId;
        try {
            auto asset = cast(CachedAsset)openAssets[req.handle];
            resp.status = message.Status.SUCCESS;
            resp.ids = asset.metadata.hashIds;
        } catch (ArrayBoundsException e) {
            log.error("MetaDataRequest on invalid handle");
            resp.status = message.Status.INVALID_HANDLE;
        }
        sendMessage(resp);
    }

    void processClose(ubyte[] buf)
    {
        scope auto req = new message.Close;
        req.decode(buf);
        log.trace("closing handle {}", req.handle);
        try {
            IServerAsset asset = openAssets[req.handle];
            openAssets.remove(req.handle);
            freeFileHandles.push(req.handle);
            asset.unRef();
        } catch (ArrayBoundsException e) {
            log.error("tried to Close invalid handle");
            return;
        }
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
