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

module daemon.cache.manager;

private import tango.core.Exception;
private import tango.io.device.File;
private import tango.io.FilePath;
private import tango.text.Ascii;
private import tango.text.Util;
private import tango.time.Time;
private import tango.util.log.Log;

private import lib.hashes;
private import lib.protobuf;

import daemon.cache.asset;
private import daemon.cache.metadata;
private import daemon.client;
private import daemon.config;
private import daemon.routing.router;

/****************************************************************************************
 * Overseeing Cache-manager, keeping state of all cache-assets, and mapping from id:s to
 * Assets.
 *
 * Copyright: Ulrik Mikaelsson, All rights reserved
 ***************************************************************************************/
class CacheManager : IAssetSource {
protected:
    AssetMetaData hashIdMap[message.HashType][ubyte[]];
    FilePath idMapPath;
    FilePath assetDir;
    ulong maxSize;            /// Maximum allowed storage-capacity of this cache, in MB. 0=unlimited
    Router router;
    AssetMetaData localIdMap[ubyte[]];
    CachedAsset[ubyte[]] openAssets;

    static Logger log;
    static this() {
        log = Log.lookup("daemon.cache.manager");
    }
public:
    /************************************************************************************
     * Create a CacheManager with a given asset-directory and underlying Router-instance
     ***********************************************************************************/
    this(FilePath assetDir, ulong maxSize, Router router) {
        if (!(assetDir.exists && assetDir.isFolder && assetDir.isWritable))
            throw new ConfigException(assetDir.toString ~ " must be an existing writable directory");
        this.assetDir = assetDir;
        this.maxSize = maxSize;
        this.router = router;

        idMapPath = this.assetDir.dup.append("index.protobuf");
        if (idMapPath.exists) {
            loadIdMap();
            garbageCollect();
        } else {
            hashIdMap[message.HashType.SHA1] = null;
            hashIdMap[message.HashType.SHA256] = null;
            hashIdMap[message.HashType.TREE_TIGER] = null;
            hashIdMap[message.HashType.ED2K] = null;
        }
    }

    /************************************************************************************
     * Tries to find assetMetaData for specified hashIds. First match applies.
     ***********************************************************************************/
    AssetMetaData findLocalAsset(message.Identifier[] hashIds) {
        foreach (id; hashIds) {
            if ((id.type in hashIdMap) && (id.id in hashIdMap[id.type])) {
                auto assetMeta = hashIdMap[id.type][id.id];
                return assetMeta;
            }
        }
        return null;
    }

    /************************************************************************************
     * Gets the size this cache is occupying, in bytes.
     ***********************************************************************************/
    ulong size() {
        ulong retval;
        foreach (fileInfo; assetDir) {
            retval += fileInfo.bytes;
        }
        return retval;
    }

    private FilePath assetPath(ubyte[] localId) {
        return assetDir.dup.append(ascii.toLower(hex.encode(localId)));
    }
    private FilePath idxPath(ubyte[] localId) {
        return idxPath(assetPath(localId));
    }
    private FilePath idxPath(FilePath assetPath) {
        return assetPath.cat(".idx");
    }

    /************************************************************************************
     * Makes room in cache for new asset of given size. May fail, in which case it
     * returns false.
     ***********************************************************************************/
    private bool _makeRoom(ulong size) {
        AssetMetaData pickLoser() {
            AssetMetaData loser;
            Time loserMtime = Time.max;
            scope AssetMetaData[] toPurge;
            foreach (asset; this.localIdMap) {
                auto path = assetPath(asset.localId);
                try {
                    auto mtime = path.modified;
                    if (mtime < loserMtime) {
                        loser = asset;
                        loserMtime = mtime;
                    }
                } catch (IOException e) {
                    toPurge ~= asset;
                }
            }
            foreach (staleAsset; toPurge) {
                purgeAsset(staleAsset);
            }
            return loser;
        }
        log.trace("Making room for new asset of {}MB. MaxSize is {}MB", size/(1024*1024), this.maxSize);
        if (this.maxSize == 0)
            return true;
        auto maxSize = this.maxSize * 1024 * 1024;
        if (size > (maxSize / 2))
            return false; // Will not cache individual assets larger than half the cacheSize
        auto targetSize = maxSize - size;
        log.trace("This cache is {}MB, roof is {}MB for upload", this.size/(1024*1024), targetSize / (1024*1024));
        garbageCollect();
        while (this.size > targetSize) {
            auto loser = pickLoser;
            if (!loser)
                return false;
            this.purgeAsset(loser);
        }
        return true;
    }

    /************************************************************************************
     * Recieves responses for forwarded requests, and decides on caching.
     ***********************************************************************************/
    private void _forwardedCallback(OpenRequest req, IServerAsset asset, message.Status status) {
        if (status == message.Status.SUCCESS) {
            auto localAsset = findLocalAsset(asset.hashIds);
            if (!localAsset && !_makeRoom(asset.size))
                req.callback(null, message.Status.NORESOURCES);
            else {
                auto localId = localAsset ? localAsset.localId : null;
                try {
                    req.callback(new CachingAsset(assetDir, req.ids, localId, asset, &_assetLifeCycleListener), status);
                } catch (IOException e) {
                    log.error("While opening asset: {}", e);
                    if (localAsset)
                        purgeAsset(localAsset);
                    req.callback(null, message.Status.ERROR);
                }
            }
        } else {
            req.callback(null, status);
        }
    }

    /************************************************************************************
     * Remove an asset from cache.
     * TODO: Fail if asset is being locked by someone using it.
     ***********************************************************************************/
    bool purgeAsset(AssetMetaData asset) {
        log.info("Purging {}", formatMagnet(asset.hashIds, 0, null));
        if (asset.localId in localIdMap)
            localIdMap.remove(asset.localId);
        foreach (hashId; asset.hashIds) {
            if ((hashId.type in hashIdMap) && (hashId.id in hashIdMap[hashId.type]))
                hashIdMap[hashId.type].remove(hashId.id);
        }
        auto aPath = assetPath(asset.localId);
        if (aPath.exists) aPath.remove();
        auto iPath = idxPath(aPath);
        if (iPath.exists) iPath.remove();
        return true;
    }

    /************************************************************************************
     * Implements IAssetSource.findAsset. Tries to get a hold of a certain asset.
     ***********************************************************************************/
    void findAsset(OpenRequest req) {
        void fromCache(CachedAsset asset) {
            log.trace("serving {} from cache", hex.encode(asset.id));
            req.callback(asset, message.Status.SUCCESS);
        }
        void openAsset(AssetMetaData localAsset)
        in { assert(localAsset); }
        body {
            try {
                fromCache(new CachedAsset(assetDir, localAsset.localId, &_assetLifeCycleListener));
            } catch (IOException e) {
                log.error("While opening asset: {}", e);
                purgeAsset(localAsset);
            }
        }
        void forwardRequest() {
            req.pushCallback(&_forwardedCallback);
            router.findAsset(req);
        }

        log.trace("Looking up hashIds");
        auto localAsset = findLocalAsset(req.ids);
        auto localId = localAsset ? localAsset.localId : null;
        if (!localAsset) {
            log.trace("Unknown asset, forwarding {}", req);
            forwardRequest();
        } else if (localId in openAssets) {
            log.trace("Found asset in openAssets");
            fromCache(openAssets[localId]);
        } else if (idxPath(localId).exists) {
            log.trace("Incomplete asset, forwarding {}", req);
            forwardRequest();
        } else {
            log.trace("Trying to open asset");
            openAsset(localAsset);
        }
    }

    /************************************************************************************
     * Implement uploading new assets to this Cache.
     ***********************************************************************************/
    void uploadAsset(UploadRequest req) {
        try {
            if (_makeRoom(req.size)) {
                auto asset = new WriteableAsset(assetDir, req.size, &_assetLifeCycleListener);
                req.callback(asset, message.Status.SUCCESS);
            } else {
                req.callback(null, message.Status.NORESOURCES);
            }
        } catch (IOException e) {
            log.error("While opening upload asset: {}", e);
            req.callback(null, message.Status.NOTFOUND);
        }
    }

private:
    /************************************************************************************
     * Listen to managed assets, and update appropriate indexes
     ***********************************************************************************/
    void _assetLifeCycleListener(CachedAsset asset, AssetState state) {
        switch (state) {
        case AssetState.ALIVE:
            openAssets[asset.id] = asset;
            break;
        case AssetState.GOTIDS:
            addToIdMap(asset.metadata);
            break;
        case AssetState.DEAD:
            openAssets.remove(asset.id);
            break;
        }
    }

    /*************************************************************************
     * The IdMap is a dummy-object for storing the mapping between hashIds
     * and localIds.
     ************************************************************************/
    class IdMap { // TODO: Re-work protobuf-lib so it isn't needed
        AssetMetaData[] assets;
        mixin MessageMixin!(PBField!("assets",    1)());
    }

    /*************************************************************************
     * Load id-mappings through IdMap
     ************************************************************************/
    void loadIdMap() {
        scope auto mapsrc = new IdMap();
        scope auto fileContent = cast(ubyte[])File.get(idMapPath.toString);
        mapsrc.decode(fileContent);
        foreach (asset; mapsrc.assets) {
            localIdMap[asset.localId] = asset;
            foreach (id; asset.hashIds)
                hashIdMap[id.type][id.id] = asset;
        }
    }

    /*************************************************************************
     * Walks through assets in dir, purging those not referenced by the idmap
     ************************************************************************/
    void garbageCollect() {
        log.info("Beginning garbage collection");
        localIdMap = localIdMap.init;
        foreach (typeMap; hashIdMap) {
            foreach (asset; typeMap) {
                localIdMap[asset.localId] = asset;
            }
        }
        saveIdMap();
        ubyte[LOCALID_LENGTH] idbuf;
        auto path = assetDir.dup.append("dummy");
        ulong cleaned;
        foreach (fileInfo; assetDir) {
            char[] name, suffix;
            name = head(fileInfo.name, ".", suffix);
            if (name.length==(idbuf.length*2) && (suffix=="idx" || suffix=="")) {
                auto id = hex.decode(name, idbuf);
                if (!(id in localIdMap)) {
                    path.name = fileInfo.name;
                    path.remove();
                    cleaned += fileInfo.bytes;
                }
            }
        }
        log.info("Garbage collection done. {} KB freed", (cleaned + 512) / 1024);
    }

    /*************************************************************************
     * Save id-mappings with IdMap
     ************************************************************************/
    void saveIdMap() {
        scope auto map = new IdMap;
        map.assets = localIdMap.values;
        File.set(idMapPath.toString, map.encode());
    }

    /*************************************************************************
     * Add an asset to the id-maps
     ************************************************************************/
    void addToIdMap(AssetMetaData asset) {
        localIdMap[asset.localId] = asset;
        foreach (id; asset.hashIds) {
            hashIdMap[id.type][id.id] = asset;
        }
        saveIdMap();
    }
}
