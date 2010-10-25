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
private import tango.core.Thread;
private import tango.io.device.File;
private import tango.io.FilePath;
private import tango.io.FileSystem;
private import tango.math.random.Random;
version (Posix) import tango.stdc.posix.sys.stat;
private import tango.text.Ascii;
private import tango.text.convert.Format;
private import tango.text.Util;
private import tango.time.Time;
private import tango.util.log.Log;

static if ( !is(typeof(fdatasync) == function ) )
    extern (C) int fdatasync(int);

private import lib.asset;
private import lib.hashes;
private import lib.protobuf;

import daemon.cache.asset;
private import daemon.cache.metadata;
private import daemon.client;
private import daemon.config;
private import daemon.routing.router;

alias WeakReference!(File) AssetRef;
const FS_MINFREE = 0.1; // Amount of filesystem that should always be kept unused.
const M = 1024*1024;

const FLUSH_INTERVAL_SEC = 30;

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
        void onStatusUpdate(IAsset asset, message.Status sCode, message.AssetStatus s) {
            if (sCode != sCode.SUCCESS)
                setAsset(null);
        }
        synchronized BaseAsset setAsset(BaseAsset asset) {
            if (this.asset)
                this.asset.detachWatcher(&onStatusUpdate);
            _openAsset.set(asset);
            if (asset)
                asset.attachWatcher(&onStatusUpdate);
            return asset;
        }
        synchronized BaseAsset openAsset() {
            if (auto retval = cast(BaseAsset)_openAsset()) {
                return retval;
            } else if (idxPath.exists) {
                return null;
            } else {
                try {
                    return setAsset(new BaseAsset(assetPath, this, &updateHashIds));
                } catch (IOException e) {
                    log.error("While opening asset: {}", e);
                    purgeAsset(this);
                    return null;
                }
            }
        }
        synchronized BaseAsset asset() {
            if (auto retval = cast(BaseAsset)_openAsset()) {
                return retval;
            } else {
                return null;
            }
        }
        FilePath assetPath() {
            return assetDir.dup.append(ascii.toLower(hex.encode(localId)));
        }
        FilePath idxPath() {
            return assetPath.cat(".idx");
        }
        void updateHashIds(message.Identifier[] ids) {
            this.hashIds = ids;
            addToIdMap(this);
        }
    }

    /************************************************************************************
     * Create new MetaAsset with random Id
     ***********************************************************************************/
    private MetaData newMetaAsset() {
        auto newMeta = new MetaData();
        auto localId = new ubyte[LOCALID_LENGTH];
        rand.randomizeUniform!(ubyte[],false)(localId);
        newMeta.localId = localId;
        addToIdMap(newMeta);
        return newMeta;
    }

    /************************************************************************************
     * Create new MetaAsset with random Id and predetermined hashIds
     ***********************************************************************************/
    private MetaData newMetaAssetWithHashIds(message.Identifier[] hashIds) {
        auto newMeta = newMetaAsset();
        newMeta.hashIds = hashIds.dup;
        foreach (ref v; newMeta.hashIds)
            v = v.dup;
        addToIdMap(newMeta);
        return newMeta;
    }

protected:
    MetaData hashIdMap[message.HashType][ubyte[]];
    FilePath idMapPath;
    FilePath assetDir;
    ulong maxSize;            /// Maximum allowed storage-capacity of this cache, in MB. 0=unlimited
    Router router;
    MetaData localIdMap[ubyte[]];
    bool idMapDirty;
    Thread idMapFlusher;

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
            _makeRoom(0); // Make sure the cache is in good order.
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
    MetaData findMetaAsset(message.Identifier[] hashIds) {
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
                char[256] filepath = void;
                auto statres = stat(Format.sprint(filepath, "{}/{}\0", fileInfo.path, fileInfo.name).ptr, &s);
                assert(statres == 0);
                version (linux) retval += s.st_blocks * 512;
                else static assert(0, "Needs to port block-size for non-Linux POSIX.");
            } else {
                retval += fileInfo.bytes;
            }
        }
        return retval;
    }

    /************************************************************************************
     * Final startup preparation
     ***********************************************************************************/
    void start() {
        idMapFlusher = new Thread(&IdMapFlusher);
        idMapFlusher.isDaemon = true;
        idMapFlusher.start;
    }

    /************************************************************************************
     * Clean shutdown
     ***********************************************************************************/
    void shutdown() {
        idMapFlusher = null;
        saveIdMap();
    }

    /************************************************************************************
     * Makes room in cache for new asset of given size. May fail, in which case it
     * returns false.
     ***********************************************************************************/
    private synchronized bool _makeRoom(ulong size) {
        /********************************************************************************
         * Find least important asset in cache.
         *******************************************************************************/
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
        /********************************************************************************
         * Calculate how large the Cache can be according to FS-limits.
         *******************************************************************************/
        ulong constrainToFs(ulong wanted, ulong cacheSize) {
            auto dir = assetDir.toString;
            auto fsBufferSpace = cast(long)(FileSystem.totalSpace(dir) * FS_MINFREE);
            auto fsFreeSpace = cast(long)FileSystem.freeSpace(dir) - fsBufferSpace;
            auto fsAllowed = cast(long)(this.size)+fsFreeSpace;
            if (wanted > fsAllowed) {
                if (this.maxSize != 0) // Don't warn when user have specified unlimited cache
                    log.warn("FileSystem-space smaller than specified cache maxSize. Constraining cache to {}% of FileSystem.", cast(uint)((1.0-FS_MINFREE)*100));
                return fsAllowed;
            } else {
                return wanted;
            }
        }
        log.trace("Making room for new asset of {}MB. MaxSize is {}MB", size/M, this.maxSize);
        auto maxSize = this.maxSize * M;
        if (maxSize == 0)
            maxSize = maxSize.max;
        maxSize = constrainToFs(maxSize, this.size);

        if (size > (maxSize / 2))
            return false; // Will not cache individual assets larger than half the cacheSize
        auto targetSize = maxSize - size;
        log.trace("This cache is {}MB, roof is {}MB for upload", this.size/M, targetSize / M);
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
    private void _forwardedCallback(BindRead req, IServerAsset asset, message.Status sCode, message.AssetStatus s) {
        if (sCode == message.Status.SUCCESS) {
            auto metaAsset = findMetaAsset(asset.hashIds);
            bool foundAsset = metaAsset !is null;
            if (!metaAsset && req.handleIsSet) {
                if (_makeRoom(asset.size))
                    metaAsset = newMetaAssetWithHashIds(asset.hashIds);
                else
                    return req.callback(null, message.Status.NORESOURCES, null);
            }
            if (!metaAsset) {
                req.callback(asset, sCode, s); // Just forward without caching
            } else { // 
                try {
                    auto path = metaAsset.assetPath;
                    assert(cast(bool)path.exists == foundAsset);
                    auto cachingAsset = new CachingAsset(path, metaAsset, asset, &metaAsset.updateHashIds);
                    metaAsset.setAsset(cachingAsset);
                    log.trace("Responding with status {}", message.statusToString(sCode));
                    req.callback(cachingAsset, sCode, s);
                } catch (IOException e) {
                    log.error("While opening asset: {}", e);
                    if (metaAsset)
                        purgeAsset(metaAsset);
                    req.callback(null, message.Status.ERROR, null);
                }
            }
        } else {
            log.info("Forward search failed with error-code {}", message.statusToString(sCode));
            req.callback(null, sCode, null);
        }
    }

    /************************************************************************************
     * Remove an asset from cache.
     * TODO: Fail if asset is being locked by someone using it.
     ***********************************************************************************/
    synchronized bool purgeAsset(MetaData asset) {
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
    void findAsset(BindRead req) {
        void fromCache(MetaData meta, BaseAsset asset) {
            log.trace("serving {} from cache", hex.encode(meta.localId));
            req.callback(asset, message.Status.SUCCESS, null);
        }
        void forwardRequest() {
            req.pushCallback(&_forwardedCallback);
            router.findAsset(req);
        }

        log.trace("Looking up hashIds");
        auto metaAsset = findMetaAsset(req.ids);

        if (!metaAsset) {
            log.trace("Unknown asset, forwarding {}", req);
            forwardRequest();
        } else if (auto asset = metaAsset.openAsset()) {
            fromCache(metaAsset, asset);
        } else {
            log.trace("Incomplete asset, forwarding {}", req);
            forwardRequest();
        }
    }

    /************************************************************************************
     * Implement uploading new assets to this Cache.
     ***********************************************************************************/
    void uploadAsset(message.BindWrite req, BHAssetStatusCallback callback) {
        try {
            if (_makeRoom(req.size)) {
                MetaData meta = newMetaAsset();
                auto path = meta.assetPath;
                assert(!path.exists());
                auto asset = new WriteableAsset(path, meta, req.size, &meta.updateHashIds);
                asset.attachWatcher(callback);
                callback(asset, message.Status.SUCCESS, null);
            } else {
                callback(null, message.Status.NORESOURCES, null);
            }
        } catch (IOException e) {
            log.error("While opening upload asset: {}", e);
            callback(null, message.Status.NOTFOUND, null);
        }
    }

private:
    /*************************************************************************
     * The IdMap is a dummy-object for storing the mapping between hashIds
     * and localIds.
     ************************************************************************/
    class IdMap { // TODO: Re-work protobuf-lib so it isn't needed
        mixin(PBField!(MetaData[], "assets"));
        mixin ProtoBufCodec!(PBMapping("assets",    1));
    }

    /*************************************************************************
     * Load id-mappings through IdMap
     ************************************************************************/
    synchronized void loadIdMap() {
        log.info("Loading fresh Id-Maps");
        scope mapsrc = new IdMap();
        scope fileContent = cast(ubyte[])File.get(idMapPath.toString);
        mapsrc.decode(fileContent);
        foreach (asset; mapsrc.assets) {
            localIdMap[asset.localId] = asset;
            foreach (id; asset.hashIds)
                hashIdMap[id.type][id.id] = asset;
        }
        idMapDirty = false;
    }

    /*************************************************************************
     * Walks through assets in dir, purging those not referenced by the idmap
     ************************************************************************/
    synchronized void garbageCollect() {
        log.info("Beginning garbage collection");
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
    synchronized void saveIdMap() {
        scope map = new IdMap;
        synchronized (this) map.assets = localIdMap.values;
        foreach (meta; map.assets) {
            auto asset = cast(WriteableAsset)meta.asset;
            if (asset)
                asset.sync();
        }
        scope tmpFile = idMapPath.dup.cat(".tmp");
        scope file = new File (tmpFile.toString, File.ReadWriteCreate);
        file.write (map.encode());
        version (Posix)
            fdatasync(file.fileHandle);
        else
            static assert(false, "Needs Non-POSIX implementation");
        file.close();
        tmpFile.rename(idMapPath);
        idMapDirty = false;
    }

    /*************************************************************************
     * Add an asset to the id-maps
     ************************************************************************/
    synchronized void addToIdMap(MetaData asset) {
        localIdMap[asset.localId] = asset;
        foreach (id; asset.hashIds) {
            hashIdMap[id.type][id.id] = asset;
        }
        idMapDirty = true;
    }

    /************************************************************************************
     * Daemon-thread loop, flushing idMap periodically to disk.
     ***********************************************************************************/
    void IdMapFlusher() {
        while (idMapFlusher) {
            if (idMapDirty) {
                garbageCollect();
                saveIdMap();
            }
            for (int i = 0; (i < FLUSH_INTERVAL_SEC) && idMapFlusher; i++)
                Thread.sleep(1);
        }
    }
}
