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
private import tango.util.log.Log;

import daemon.server;
import daemon.cache.asset;
import daemon.cache.manager;
import lib.asset;
import lib.client;
import lib.connection;
import lib.hashes;
import message = lib.message;
import lib.protobuf;

/****************************************************************************************
 * Delegate-signature for request-notification-recievers. Reciever is responsible for
 * triggering a new req.callback, with appropriate responses.
 ***************************************************************************************/
alias void delegate(BindRead req, IServerAsset, message.Status status) BHServerOpenCallback;

/****************************************************************************************
 * Interface for the various forms of server-assets. (BaseAsset, CachingAsset,
 * ForwardedAsset...)
 ***************************************************************************************/
interface IServerAsset : IAsset {
    message.Identifier[] hashIds();
}
interface IAssetSource {
    void findAsset(daemon.client.BindRead req);
}

/****************************************************************************************
 * Structure for an incoming BindRead. Store the details of the request, should it
 * need to be asynchronously forwarded before completion.
 ***************************************************************************************/
class BindRead : message.BindRead {
    Client client;
    BHServerOpenCallback[4] _callbacks;
    ushort _callbackCounter;
    this(Client c) {
        client = c;
        pushCallback(&_callback);
    }
    final void _callback(BindRead req, IServerAsset asset, message.Status status) {
        assert(this is req);
        if (!client.closed) {
            scope resp = new message.AssetStatus;
            resp.handle = handle;
            resp.status = status;
            if (asset)
                resp.size = asset.size;

            client.openAssets[handle] = asset; // Assign to assetMap by Id
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
class BindWrite : message.BindWrite {
    Client client;
    this(Client c) {
        client = c;
    }
    final void callback(IServerAsset asset, message.Status status) {
        if (!client.closed) {
            scope resp = new message.AssetStatus;
            resp.handle = handle;
            resp.status = status;
            if (status == message.Status.SUCCESS) {
                // Allocate handle, and add to map
                client.openAssets[handle] = asset;
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
            scope resp = new message.ReadResponse;
            resp.rpcId = rpcId;
            resp.offset = remoteResp.offset;
            resp.content = remoteResp.content;
            resp.status = status;
            client.sendMessage(resp);
        }
        delete this;
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
    void open(message.Identifier[] ids, BHAssetStatusCallback openCallback, ulong uuid,
              TimeSpan timeout) { super.open(ids, openCallback, uuid, timeout); }
protected:
    void processBindRead(Connection c, ubyte[] buf)
    {
        auto req = new daemon.client.BindRead(this);
        req.decode(buf);
        if (req.idsIsSet) {
            log.trace("Got open request #{}, {}", req.uuid, formatMagnet(req.ids, 0));
            if (!req.uuidIsSet)
                req.uuid = rand.uniformR2!(ulong)(1,ulong.max);
            server.findAsset(req);
        } else {
            req.abort(message.Status.NOTFOUND);
        }
    }

    void processBindWrite(Connection c, ubyte[] buf)
    {
        if (!c.isTrusted) {
            log.warn("Got BindWrite from unauthorized client {}", this);
            return;
        }
        auto req = new daemon.client.BindWrite(this);
        req.decode(buf);
        log.trace("Got BindWrite from trusted client");
        server.uploadAsset(req);
    }

    void processReadRequest(Connection c, ubyte[] buf)
    {
        auto req = new ReadRequest(this);
        req.decode(buf);
        IAsset asset;
        try {
            asset = openAssets[req.handle];
        } catch (ArrayBoundsException e) {
            delete req;
            scope resp = new message.ReadResponse;
            resp.rpcId = req.rpcId;
            resp.status = message.Status.INVALID_HANDLE;
            return sendMessage(resp);
        }
        asset.aSyncRead(req.offset, req.size, &req.callback);
    }

    void processDataSegment(Connection c, ubyte[] buf) {
        scope req = new message.DataSegment();
        req.decode(buf);
        try {
            auto asset = cast(BaseAsset)openAssets[req.handle];
            asset.add(req.offset, req.content);
        } catch (ArrayBoundsException e) {
            log.error("DataSegment to invalid handle");
        }
    }

    void processMetaDataRequest(Connection c, ubyte[] buf) {
        // Create anon class to satisfy abstract abort().
        // MetaData is always local and never async, so don't need full state
        scope req = new class message.MetaDataRequest {
            void abort(message.Status s) {}
        };
        req.decode(buf);
        scope resp = new message.MetaDataResponse;
        resp.rpcId = req.rpcId;
        try {
            auto asset = openAssets[req.handle];
            if (asset) {
                resp.ids = asset.hashIds;
                if (resp.ids)
                    resp.status = message.Status.SUCCESS;
                else
                    resp.status = message.Status.ERROR;
            } else {
                resp.status = message.Status.INVALID_HANDLE;
            }
        } catch (ArrayBoundsException e) {
            log.error("MetaDataRequest on invalid handle");
            resp.status = message.Status.INVALID_HANDLE;
        }
        sendMessage(resp);
    }
}
