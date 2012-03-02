/****************************************************************************************
 *   Copyright: Copyright (C) 2009-2011 Ulrik Mikaelsson. All rights reserved
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
private import tango.math.random.Random;
private import tango.net.device.Socket;
private import tango.time.Time;
private import tango.util.log.Log;

import daemon.server;
import daemon.store.cache.manager;
import daemon.refcount;

import lib.asset;
import lib.client;
import lib.connection;
import lib.hashes;
import message = lib.message;
import lib.protobuf;

auto MAX_OPEN_ASSETS = 4096;

/****************************************************************************************
 * Interface for the various forms of server-assets. (BaseAsset, CachingAsset,
 * ForwardedAsset...)
 ***************************************************************************************/
interface IServerAsset : IAsset {
    message.Identifier[] hashIds();

    // TODO: Should really inherit IRefCounted, but that seems to cause a stupid compiler-bug.
    void takeRef(Object o);
    void dropRef(Object o);
}

interface IAssetSource {
    /*************************************************************************************
     * Tries to lookup a specified asset and serve it.
     * Returns: Whether this IAssetSource handled the request or not. Please not that 
     *          "handling" is not the same as finding. I.E. an AssetSource can handle the
     *          request by replying NOTFOUND. On the other hand, not handling means
     *          another asset-source might be tried.
     ************************************************************************************/
    bool findAsset(daemon.client.BindRead req);
}

/****************************************************************************************
 * Structure for an incoming BindRead. Store the details of the request, should it
 * need to be asynchronously forwarded before completion.
 ***************************************************************************************/
class BindRead : message.BindRead {
    alias void delegate(BindRead req, IServerAsset asset, message.Status sCode, message.AssetStatus s) CallBack;

    Client client;
    CallBack[4] _callbacks;
    ushort _callbackCounter;
    this(Client c) {
        client = c;
    }
    final void callback(IServerAsset asset, message.Status sCode, message.AssetStatus status) {
        _callbacks[--_callbackCounter](this, asset, sCode, status);
    }
    final void pushCallback(CallBack cb) in {
        assert(_callbackCounter < _callbacks.length);
        assert(cb !is null);
    } body {
        _callbacks[_callbackCounter++] = cb;
    }
    void abort(message.Status s) {
        callback(null, s, null);
    }
}

/****************************************************************************************
 * Structure for an incoming ReadRequest
 ***************************************************************************************/
class ReadRequest : message.ReadRequest {
    Client client;
    bool answered = false;
public:
    this(Client c) {
        client = c;
    }
    final void callback(message.Status status, message.ReadRequest remoteReq, message.ReadResponse remoteResp) {
        assert(!answered);
        if (client && !client.closed) {
            scope resp = new message.ReadResponse;
            resp.rpcId = rpcId;
            resp.status = status;
            if (remoteResp && (status == message.Status.SUCCESS)) {
                resp.offset = remoteResp.offset;
                resp.content = remoteResp.content;
            }
            client.sendNotification(resp);
        }
        answered = true;
    }
    void abort(message.Status s) {
        callback(s, null, null);
    }
}

class Client : lib.client.Client {
    /************************************************************************************
     * Represents a ServerAsset bound to a client-handle
     ***********************************************************************************/
    class BoundAsset : IAsset {
        uint handle;
        IServerAsset assetSource;
        bool closed;
    protected:
        /// Construct from BindRead request
        this (BindRead req) {
            handle = req.handle;
            setAsset(handle, this);
            req.pushCallback(&onBindReadReply);
            server.findAsset(req);
        }
        this (message.BindWrite req) {
            handle = req.handle;
            setAsset(handle, this);
            server.uploadAsset(req, &onAssetStatus);
        }
    private:
        void onBindReadReply(BindRead _, IServerAsset asset, message.Status sCode, message.AssetStatus s) {
            if (asset) {
                log.trace("Registered for statusUpdates on handle {}", handle);
                asset.attachWatcher(&onAssetStatus);
            }
            return onAssetStatus(asset, sCode, s);
        }
        void onAssetStatus(IAsset asset, message.Status sCode, message.AssetStatus s) {
            log.trace("Informing client on status {} on handle {}", message.statusToString(sCode), handle);
            auto newAssetSource = cast(IServerAsset)asset;
            if (newAssetSource && newAssetSource !is assetSource) {
                newAssetSource.takeRef(this);

                if (closed) {
                    newAssetSource.dropRef(this); // Immediately drop the reference again if we're already closed.
                } else if (assetSource is null) {
                    assetSource = newAssetSource;
                } else { // Detect invalid assigns.
                    newAssetSource.dropRef(this);
                    throw new AssertException("Attempted to change AssetSource of existing BoundAsset", __FILE__, __LINE__);
                }
            }
            if (!closed) {
                scope resp = new message.AssetStatus;
                resp.handle = handle;
                resp.status = sCode;
                if (assetSource && sCode == message.Status.SUCCESS) {
                    resp.size = assetSource.size;
                    resp.ids = assetSource.hashIds;
                }
                if (s) {
                    resp.availability = s.availability;
                }
                sendNotification(resp);
            }
        }
    public:
        ulong size() {
            return assetSource ? assetSource.size : 0;
        }
        void close() {
            log.trace("Closed asset {}", handle);
            closed = true;
            if (assetSource) {
                assetSource.detachWatcher(&onAssetStatus);
                assetSource.dropRef(this);
            }
            assetSource = null;
            setAsset(handle,null);
        }
        void attachWatcher(BHAssetStatusCallback) {} // Doesn't make sense?
        void detachWatcher(BHAssetStatusCallback) {} // Doesn't make sense?
        message.Identifier[] hashIds() {
            return assetSource ? assetSource.hashIds : null;
        }
        void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
            if (assetSource) {
                return assetSource.aSyncRead(offset, length, cb);
            } else {
                cb(message.Status.NOTFOUND, null, null);
            }
        }
        void addDataSegment(message.DataSegment req) {
            auto asset = cast(CacheManager.Asset)assetSource;
            if (asset && (asset.state == asset.State.INCOMPLETE))
                asset.add(req.offset, req.content);
            else
                log.warn("Client trying to write to non-writeable asset!");
        }
    }
private:
    Server server;
    CacheManager cacheMgr;
    BoundAsset[] openAssets;
    Logger log;
public:
    this (Server server, Connection c) {
        this.server = server;
        this.cacheMgr = server.cacheMgr;
        this.log = Log.lookup("daemon.client");

        super(server.name, c, false);
    }

    /************************************************************************************
     * Re-declared _open from lib.Client to make it publicly visible in the daemon.
     ***********************************************************************************/
    void open(message.Identifier[] ids, BHAssetStatusCallback openCallback, ulong uuid,
              TimeSpan timeout) { super.open(ids, openCallback, uuid, timeout, true); }

    /************************************************************************************
     * Cleanup when client closes
     ***********************************************************************************/
    void close() {
        foreach (asset; openAssets) if (asset)
            asset.close();
        openAssets = null;
        super.close();
    }

    synchronized void dumpStats(Time now) {
        log.trace("Serving {} Assets", downstreamAssetCount);
        super.dumpStats(now);
    }

    synchronized uint downstreamAssetCount() {
        uint count;
        foreach (asset; openAssets)
            if (asset) count ++;
        return count;
    }
private:
    BoundAsset getAsset(uint i) {
        if (i >= openAssets.length)
            return null;
        else
            return openAssets[i];
    }

    BoundAsset setAsset(uint i, BoundAsset asset) {
        if (i > MAX_OPEN_ASSETS)
            throw new IllegalElementException("Asset handle too large");
        if (i >= openAssets.length)
            openAssets.length = openAssets.length + 5 + (i-openAssets.length)*2;
        return openAssets[i] = asset;
    }

protected:
    void _onPeerPresented(Connection c) {
        auto config = server.config;
        auto keyInfo = config.findConnectionParams(c.peername);

        auto peerAddress = c.remoteAddress;
        auto peerAccepted = keyInfo !is null
                            || config.allowanon
                            || (peerAddress.addressFamily == AddressFamily.UNIX)
                            || ((peerAddress.addressFamily == AddressFamily.INET)
                                && ((cast(IPv4Address)peerAddress).addr == 0x7f000001)); // 127.0.0.1

        auto cipher = keyInfo ? keyInfo.sendCipher : message.CipherType.CLEARTEXT;
        auto sharedKey = keyInfo ? keyInfo.sharedKey : null;

        if (!peerAccepted)
            throw new AuthenticationFailure("Server does not allow anonymous connections.");
        else if ((sharedKey || cipher) && c.protoversion < 2)
            throw new AuthenticationFailure("Auth required from client running old protocol.");
        else
            super._onPeerPresented(c);

        if (!c.myname)
            c.sayHello(server.name, cipher, sharedKey);

        this.log = Log.lookup("daemon.client."~c.peername);
    }

    void processBindRead(Connection c, ubyte[] buf)
    {
        auto req = new daemon.client.BindRead(this);
        req.decode(buf);

        // Test if asset-handle is previously used.
        auto openAsset = getAsset(req.handle);
        if (openAsset) {
            openAsset.close();
            setAsset(req.handle, null);
        }

        if (req.idsIsSet) {
            log.trace("Got open request #{}, {}", req.uuid, formatMagnet(req.ids, 0));
            if (!req.uuidIsSet)
                req.uuid = rand.uniformR2!(ulong)(1,ulong.max);
            setAsset(req.handle, new BoundAsset(req));
        } else {
            scope resp = new message.AssetStatus();
            resp.handle = req.handle;
            resp.status = message.Status.NOTFOUND;
            sendNotification(resp);
        }
    }

    void processBindWrite(Connection c, ubyte[] buf)
    {
        if (!c.isTrusted) {
            log.warn("Got BindWrite from unauthorized client {}", this);
            return;
        }
        auto req = new message.BindWrite;
        req.decode(buf);
        log.trace("Got BindWrite from trusted client");
        auto asset = new BoundAsset(req);
    }

    void processReadRequest(Connection c, ubyte[] buf)
    {
        auto req = new ReadRequest(this);
        req.decode(buf);
        if (IAsset asset = getAsset(req.handle)) {
            asset.aSyncRead(req.offset, req.size, &req.callback);
        } else {
            log.error("ReadRequest for unknown asset ", req.handle);
            scope resp = new message.ReadResponse;
            resp.rpcId = req.rpcId;
            resp.status = message.Status.INVALID_HANDLE;
            sendNotification(resp);
        }
    }

    void processDataSegment(Connection c, ubyte[] buf) {
        scope req = new message.DataSegment();
        req.decode(buf);
        auto asset = getAsset(req.handle);
        if (asset) {
            asset.addDataSegment(req);
        } else {
            log.error("DataSegment to invalid handle");
        }
    }
}
