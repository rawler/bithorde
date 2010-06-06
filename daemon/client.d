/****************************************************************************************
 *   Copyright: Copyright (C) 2009-2010 Ulrik Mikaelsson. All rights reserved
 *
 *   License:
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 ***************************************************************************************/
module daemon.client;

private import tango.core.Exception;
private import tango.core.Memory;
private import tango.math.random.Random;
private import tango.net.device.Socket;
private import tango.time.Time;
private import tango.util.container.more.Stack;
private import tango.util.log.Log;

import daemon.server;
import daemon.cache.asset;
import daemon.cache.manager;
import lib.asset;
import lib.client;
import message = lib.message;
import lib.protobuf;

/****************************************************************************************
 * Delegate-signature for request-notification-recievers. Reciever is responsible for
 * triggering a new req.callback, with appropriate responses.
 ***************************************************************************************/
alias void delegate(OpenRequest req, IServerAsset, message.Status status) BHServerOpenCallback;

/****************************************************************************************
 * Interface for the various forms of server-assets. (BaseAsset, CachingAsset,
 * ForwardedAsset...)
 ***************************************************************************************/
interface IServerAsset : IAsset {
    message.Identifier[] hashIds();
}
interface IAssetSource {
    void findAsset(daemon.client.OpenRequest req);
}

/****************************************************************************************
 * Structure for an incoming OpenRequest. Store the details of the request, should it
 * need to be asynchronously forwarded before completion.
 ***************************************************************************************/
class OpenRequest : message.OpenRequest {
    Client client;
    BHServerOpenCallback[4] _callbacks;
    ushort _callbackCounter;
    this(Client c) {
        client = c;
        pushCallback(&_callback);
    }
    final void _callback(OpenRequest req, IServerAsset asset, message.Status status) {
        assert(this is req);
        if (!client.closed) {
            scope auto resp = new message.OpenResponse;
            resp.rpcId = rpcId;
            resp.status = status;
            if (status == message.Status.SUCCESS) {
                // Allocate handle, and add to map
                auto handle = client.allocateFreeHandle(this.handle);
                client.openAssets[handle] = asset;
                resp.handle = handle;
                resp.size = asset.size;
            }
            client.sendMessage(resp);
        }
        delete this;
    }
    final void callback(IServerAsset asset, message.Status status) {
        _callbacks[--_callbackCounter](this, asset, status);
    }
    final void pushCallback(BHServerOpenCallback cb) {
        assert(_callbackCounter < _callbacks.length);
        _callbacks[_callbackCounter++] = cb;
    }
    void abort(message.Status s) {
        callback(null, s);
    }
}

/****************************************************************************************
 * Structure for an incoming UploadReuest.
 ***************************************************************************************/
class UploadRequest : message.UploadRequest {
    Client client;
    this(Client c) {
        client = c;
    }
    final void callback(IServerAsset asset, message.Status status) {
        if (!client.closed) {
            scope auto resp = new message.OpenResponse;
            resp.rpcId = rpcId;
            resp.status = status;
            if (status == message.Status.SUCCESS) {
                // Allocate handle, and add to map
                auto handle = client.allocateFreeHandle(this.handle);
                client.openAssets[handle] = asset;
                resp.handle = handle;
            }
            client.sendMessage(resp);
        }
    }
    void abort(message.Status s) {
        callback(null, s);
    }
}

/****************************************************************************************
 * Structure for an incoming ReadRequest
 ***************************************************************************************/
class ReadRequest : message.ReadRequest {
    Client client;
public:
    this(Client c) {
        client = c;
    }
    final void callback(IAsset asset, message.Status status, message.ReadRequest remoteReq, message.ReadResponse remoteResp) {
        if (client) {
            scope auto resp = new message.ReadResponse;
            resp.rpcId = rpcId;
            resp.offset = remoteResp.offset;
            resp.content = remoteResp.content;
            resp.status = status;
            client.sendMessage(resp);
        }
    }
    void abort(message.Status s) {
        callback(null, s, null, null);
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
        this.log = Log.lookup("daemon.client."~peername);
    }

    /************************************************************************************
     * Re-declared _open from lib.Client to make it publicly visible in the daemon.
     ***********************************************************************************/
    void open(message.Identifier[] ids, BHOpenCallback openCallback, ulong uuid,
              TimeSpan timeout) { super.open(ids, openCallback, uuid, timeout); }
protected:
    void processOpenRequest(ubyte[] buf)
    {
        auto req = new daemon.client.OpenRequest(this);
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
        auto req = new daemon.client.UploadRequest(this);
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
            auto asset = cast(BaseAsset)openAssets[req.handle];
            asset.add(req.offset, req.content);
        } catch (ArrayBoundsException e) {
            log.error("DataSegment to invalid handle");
        }
    }

    void processMetaDataRequest(ubyte[] buf) {
        // Create anon class to satisfy abstract abort().
        // MetaData is always local and never async, so don't need full state
        scope auto req = new class message.MetaDataRequest {
            void abort(message.Status s) {}
        };
        req.decode(buf);
        scope auto resp = new message.MetaDataResponse;
        resp.rpcId = req.rpcId;
        try {
            auto asset = cast(BaseAsset)openAssets[req.handle];
            if (asset && asset.metadata) {
                resp.status = message.Status.SUCCESS;
                resp.ids = asset.metadata.hashIds;
            } else {
                resp.status = message.Status.INVALID_HANDLE;
            }
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
        } catch (ArrayBoundsException e) {
            log.error("tried to Close invalid handle");
            return;
        }
    }
private:
    /************************************************************************************
     * Allocates an unused file handle for the transaction.
     * requestedHandle - Just a suggestion, may not end up being what's allocated
     ***********************************************************************************/
    ushort allocateFreeHandle(uint requestedHandle)
    {
        if (freeFileHandles.size > 0)
            return freeFileHandles.pop();
        else
            return nextNewHandle++;
    }
}
