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
private import tango.core.WeakRef;
private import tango.io.device.File;
private import tango.io.FilePath;
private import tango.math.random.Random;
version (Posix) import tango.stdc.posix.sys.stat;
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

alias WeakReference!(File) AssetRef;

/****************************************************************************************
 * Overseeing Cache-manager, keeping state of all cache-assets, and mapping from id:s to
 * Assets.
 *
 * Copyright: Ulrik Mikaelsson, All rights reserved
 ***************************************************************************************/
class CacheManager : IAssetSource {
    class MetaData : daemon.cache.metadata.AssetMetaData {
        private AssetRef _openAsset;
        this() {
            _openAsset = new AssetRef(null);
        }
        BaseAsset setAsset(BaseAsset asset) {
            _openAsset.set(asset);
            return asset;
        }
        BaseAsset getAsset() {
            return cast(BaseAsset)_openAsset();
        }
        FilePath assetPath() {
            return assetDir.dup.append(ascii.toLower(hex.encode(localId)));
        }
        FilePath idxPath() {
            return assetPath.cat(".idx");
        }
    }

protected:
    MetaData hashIdMap[message.HashType][ubyte[]];
    FilePath idMapPath;
    FilePath assetDir;
    ulong maxSize;            /// Maximum allowed storage-capacity of this cache, in MB. 0=unlimited
    Router router;
    MetaData localIdMap[ubyte[]];

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
    MetaData findLocalAsset(message.Identifier[] hashIds) {
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
            version (Posix) {
                stat_t s;
                assert(stat((fileInfo.path~'\0').ptr, &s) == 0);
                version (linux) retval += s.st_blocks * 512;
                else static assert(0, "Needs to port block-size for non-Linux POSIX.");
            } else {
                retval += fileInfo.bytes;
            }
        }
        return retval;
    }

    /************************************************************************************
     * Makes room in cache for new asset of given size. May fail, in which case it
     * returns false.
     ***********************************************************************************/
    private bool _makeRoom(ulong size) {
        MetaData pickLoser() {
            MetaData loser;
            Time loserMtime = Time.max;
            scope MetaData[] toPurge;
            foreach (asset; this.localIdMap) {
                try {
                    auto mtime = asset.assetPath.modified;
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
                bool foundAsset = localAsset !is null;
                if (!localAsset) {
                    localAsset = new MetaData();
                    localAsset.localId = new ubyte[LOCALID_LENGTH];
                    localAsset.hashIds = asset.hashIds.dup;
                    foreach (ref v; localAsset.hashIds)
                        v = v.dup;
                    rand.randomizeUniform!(ubyte[],false)(localAsset.localId);
                }
                try {
                    auto path = localAsset.assetPath;
                    assert(cast(bool)path.exists == foundAsset);
                    auto cachingAsset = new CachingAsset(path, localAsset, asset, &_assetLifeCycleListener);
                    localAsset.setAsset(cachingAsset);
                    req.callback(cachingAsset, status);
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
    bool purgeAsset(MetaData asset) {
        log.info("Purging {}", formatMagnet(asset.hashIds, 0, null));
        if (asset.localId in localIdMap)
            localIdMap.remove(asset.localId);
        foreach (hashId; asset.hashIds) {
            if ((hashId.type in hashIdMap) && (hashId.id in hashIdMap[hashId.type]))
                hashIdMap[hashId.type].remove(hashId.id);
        }
        auto aPath = asset.assetPath;
        if (aPath.exists) aPath.remove();
        auto iPath = asset.idxPath;
        if (iPath.exists) iPath.remove();
        return true;
    }

    /************************************************************************************
     * Implements IAssetSource.findAsset. Tries to get a hold of a certain asset.
     ***********************************************************************************/
    void findAsset(OpenRequest req) {
        void fromCache(MetaData meta, BaseAsset asset) {
            log.trace("serving {} from cache", hex.encode(meta.localId));
            meta.setAsset(asset);
            req.callback(asset, message.Status.SUCCESS);
        }
        void openAsset(MetaData meta)
        in { assert(meta); }
        body {
            try {
                auto path = meta.assetPath;
                auto openAsset = new BaseAsset(path, meta, &_assetLifeCycleListener);
                fromCache(meta, openAsset);
            } catch (IOException e) {
                log.error("While opening asset: {}", e);
                purgeAsset(meta);
                req.callback(null, message.Status.ERROR);
            }
        }
        void forwardRequest() {
            req.pushCallback(&_forwardedCallback);
            router.findAsset(req);
        }

        log.trace("Looking up hashIds");
        auto localAsset = findLocalAsset(req.ids);

        if (!localAsset) {
            log.trace("Unknown asset, forwarding {}", req);
            forwardRequest();
        } else if (localAsset.getAsset()) {
            log.trace("Asset already open");
            fromCache(localAsset, localAsset.getAsset());
        } else if (localAsset.idxPath.exists) {
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
                MetaData meta = new MetaData;
                auto localId = meta.localId = new ubyte[LOCALID_LENGTH];
                rand.randomizeUniform!(ubyte[],false)(localId);
                auto path = meta.assetPath;
                assert(!path.exists());
                auto asset = new WriteableAsset(path, meta, req.size, &_assetLifeCycleListener);
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
    void _assetLifeCycleListener(BaseAsset asset, AssetState state) {
        switch (state) {
        case AssetState.GOTIDS:
            addToIdMap(cast(MetaData)asset.metadata);
            break;
        }
    }

    /*************************************************************************
     * The IdMap is a dummy-object for storing the mapping between hashIds
     * and localIds.
     ************************************************************************/
    class IdMap { // TODO: Re-work protobuf-lib so it isn't needed
        MetaData[] assets;
        mixin MessageMixin!(PBField!("assets",    1)());
    }

    /*************************************************************************
     * Load id-mappings through IdMap
     ************************************************************************/
    void loadIdMap() {
        log.info("Loading fresh Id-Maps");
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
    void addToIdMap(MetaData asset) {
        localIdMap[asset.localId] = asset;
        foreach (id; asset.hashIds) {
            hashIdMap[id.type][id.id] = asset;
        }
        saveIdMap();
    }
}
