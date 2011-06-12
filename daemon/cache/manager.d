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
private import tango.time.Clock;
private import tango.util.Convert;
private import tango.util.log.Log;

static if ( !is(typeof(fdatasync) == function ) )
    extern (C) int fdatasync(int);

private import lib.asset;
static private import base32 = lib.base32;
private import lib.hashes;
private import lib.httpserver;
private import lib.protobuf;

private import daemon.cache.asset;
private import daemon.cache.metadata;
private import daemon.client;
private import daemon.config;
private import daemon.refcount;
private import daemon.routing.router;

const FS_MINFREE = 0.1; // Amount of filesystem that should always be kept unused.
const M = 1024*1024;

const FLUSH_INTERVAL_SEC = 30;

/****************************************************************************************
 * Overseeing Cache-manager, keeping state of all cache-assets, and mapping from id:s to
 * Assets.
 ***************************************************************************************/
class CacheManager : IAssetSource {
    class MetaData : daemon.cache.metadata.AssetMetaData, IServerAsset {
        mixin IAsset.StatusSignal;
        mixin RefCountTarget;

        private BaseAsset _openAsset;

        void onStatusUpdate(IAsset asset, message.Status sCode, message.AssetStatus s) {
            if (sCode != sCode.SUCCESS)
                setAsset(null);
        }

        private BaseAsset setAsset(BaseAsset newAsset) {
            if (_openAsset) {
                detachWatcher(&onStatusUpdate);
                _openAsset.close();
            }
            _openAsset = newAsset;
            if (_openAsset)
                attachWatcher(&onStatusUpdate);
            return _openAsset;
        }

        void onBackingUpdate(IAsset backing, message.Status sCode, message.AssetStatus s) {
            _statusSignal.call(this, sCode, s);
        }

        /********************************************************************************
         * Throws: IOException if asset is not found
         *******************************************************************************/
        MetaData openRead() {
            if (isOpen) { // If something is already holding it open, just use it.
                return this;
            } else if (idxPath.exists) {
                return null;
            } else {
                setAsset(new BaseAsset(assetPath, this));
                return this;
            }
        }

        MetaData openUpload(ulong size) {
            setAsset(new UploadAsset(assetPath, this, size, &updateHashIds, usefsync));
            return this;
        }

        MetaData openCaching(IServerAsset sourceAsset) {
            setAsset(new CachingAsset(assetPath, this, sourceAsset, &updateHashIds, usefsync));
            return this;
        }

        bool isOpen() {
            return _openAsset !is null;
        }
        bool isWritable() {
            return (cast(WriteableAsset)_openAsset) !is null;
        }

        void close() {
            scope(exit) _openAsset = null;
            if (_openAsset)
                _openAsset.close();
        }

        void sync() {
            auto asset = cast(WriteableAsset)_openAsset;
            if (asset)
                asset.sync();
        }

        ulong size() {
            if (_openAsset)
                return _openAsset.size;
            else
                assert(false);
        }

        void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
            if (_openAsset)
                return _openAsset.aSyncRead(offset, length, cb);
            else
                assert(false, "Trying to read from closed asset.");
        }

        void add(ulong offset, ubyte[] data) {
            if (_openAsset)
                return _openAsset.add(offset, data);
            else
                assert(false, "Trying to add to closed asset.");
        }

        message.Identifier[] hashIds() {
            return super.hashIds();
        }
        message.Identifier[] hashIds(message.Identifier[] ids) {
            return super.hashIds(ids);
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

            _statusSignal.call(this, message.Status.SUCCESS, null);
        }

        char[] magnetLink() {
            if (isOpen)
                return formatMagnet(hashIds, size);
            else
                return formatMagnet(hashIds, 0);
        }

        char[] localIdBase32() {
            return base32.encode(localId);
        }
    }

    /************************************************************************************
     * Create new MetaAsset with random Id
     ***********************************************************************************/
    private MetaData newMetaAsset() {
        auto newMeta = new MetaData();
        auto localId = new ubyte[LOCALID_LENGTH];
        rand.randomizeUniform!(ubyte[],false)(localId);
        while (localId in localIdMap) {
            log.warn("Random generated ID conflict with previously used ID.");
            rand.randomizeUniform!(ubyte[],false)(localId);
        }
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
    bool usefsync;

    static Logger log;
    static this() {
        log = Log.lookup("daemon.cache.manager");
    }
public:
    /************************************************************************************
     * Create a CacheManager with a given asset-directory and underlying Router-instance
     ***********************************************************************************/
    this(FilePath assetDir, ulong maxSize, bool usefsync, Router router) {
        if (!(assetDir.exists && assetDir.isFolder && assetDir.isWritable))
            throw new ConfigException(assetDir.toString ~ " must be an existing writable directory");
        this.assetDir = assetDir;
        this.maxSize = maxSize;
        this.usefsync = usefsync;
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
                assert(statres == 0); // TODO: Should always check return value
                version (linux) retval += s.st_blocks * 512;
                else static assert(0, "Needs to port block-size for non-Linux POSIX.");
            } else {
                retval += fileInfo.bytes;
            }
        }
        return retval;
    }

    /************************************************************************************
     * Expose the number of assets in cache
     ***********************************************************************************/
    uint assetCount() {
        return localIdMap.length;
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
            auto loserRating = long.max;
            foreach (meta; this.localIdMap) {
                if (meta.isOpen) // Is Open
                    continue;
                auto rating = meta.rating;
                if (rating < loserRating) {
                    loser = meta;
                    loserRating = rating;
                }
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

        debug (Performance) {
            Time started = Clock.now;
            scope(exit) { log.trace("MakeRoom took {}ms",(Clock.now-started).millis); }
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
                    assert(cast(bool)metaAsset.assetPath.exists == foundAsset);
                    metaAsset.openCaching(asset);
                    log.trace("Responding with status {}", message.statusToString(sCode));
                    req.callback(metaAsset, sCode, s);
                } catch (IOException e) {
                    log.error("While opening asset: {}", e);
                    req.callback(null, message.Status.ERROR, null);
                }
            }
        } else {
            req.callback(null, sCode, null);
        }
    }

    /************************************************************************************
     * Remove an asset from cache.
     ***********************************************************************************/
    synchronized bool purgeAsset(MetaData asset) {
        if (asset.hashIds.length) {
            log.info("Purging {}", formatMagnet(asset.hashIds, 0, null));
        } else {
            log.info("Purging <unknown asset>");
        }

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
        void fromCache(MetaData meta) {
            log.trace("serving {} from cache", hex.encode(meta.localId));
            req.callback(meta, message.Status.SUCCESS, null);
        }
        void forwardRequest() {
            req.pushCallback(&_forwardedCallback);
            router.findAsset(req);
        }
        IServerAsset tryOpen(MetaData meta) {
            try { // Needs to handle IOErrors here, to not lock meta while purging.
                return meta.openRead();
            } catch (IOException e) {
                log.error("While opening asset: {}", e);
                return null;
            }
        }

        auto metaAsset = findMetaAsset(req.ids);
        if (!metaAsset) {
            forwardRequest();
        } else if (tryOpen(metaAsset)) {
            fromCache(metaAsset);
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
                meta.openUpload(req.size);
                meta.attachWatcher(callback);
                callback(meta, message.Status.SUCCESS, null);
            } else {
                callback(null, message.Status.NORESOURCES, null);
            }
        } catch (IOException e) {
            log.error("While opening upload asset: {}", e);
            callback(null, message.Status.NOTFOUND, null);
        }
    }

    /************************************************************************************
     * Handles incoming management-requests
     ***********************************************************************************/
    MgmtEntry[] onManagementRequest(char[][] path) {
        MgmtEntry[] res;
        foreach (asset; localIdMap) {
            auto assetOpen = asset.isOpen ? "open" : "closed";
            auto desc = assetOpen ~ ", " ~ asset.magnetLink;
            res ~= MgmtEntry(asset.localIdBase32, desc);
        }
        return res;
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
        auto now = Clock.now;
        auto currentMaxRating = now.unix.millis;
        foreach (asset; mapsrc.assets) {
            if (asset.rating > currentMaxRating) {
                log.warn("Implausibly high asset-rating {} on {}. Have the system clock been reset? Adjusting...",
                            asset.rating, ascii.toLower(hex.encode(asset.localId)));
                asset.setMaxRating(now);
            }
            localIdMap[asset.localId] = asset;
            foreach (id; asset.hashIds)
                hashIdMap[id.type][id.id] = asset;
        }
        idMapDirty = false;
    }

    /************************************************************************************
     * Walks through assets in dir, purging those not referenced by the idmap then walks
     * through the localIdMap, purging those ids not found in the asset directory.
     ***********************************************************************************/
    synchronized void garbageCollect() {
        debug (Performance) {
            Time started = Clock.now;
            scope(exit) { log.trace("Asset-GC took {}ms",(Clock.now-started).millis); }
        }

        log.info("Beginning garbage collection");

        /* remove redundant and faulty assets from localIdMap */ {
            scope ubyte[][] staleAssets;
            foreach (asset; localIdMap) {
                if (!asset.assetPath.exists) {
                    foreach (id; asset.hashIds) if (id.type in hashIdMap) {
                        auto map = hashIdMap[id.type];
                        if ((id.id in map) &&
                            (map[id.id] == asset))
                            map.remove(id.id);
                    }
                    staleAssets ~= asset.localId;
                } else foreach (id; asset.hashIds) {
                    if ((id.type in hashIdMap) &&
                        (id.id in hashIdMap[id.type]) &&
                        (hashIdMap[id.type][id.id] != asset))
                    staleAssets ~= asset.localId;
                }
            }
            foreach (id; staleAssets) {
                localIdMap.remove(id);
            }
        }

        ulong bytesFreed;
        /* Clear out files not referenced by localIdMap */ {
            ubyte[LOCALID_LENGTH] idbuf;
            auto path = assetDir.dup.append("dummy");
            foreach (fileInfo; assetDir) {
                char[] name, suffix;
                name = head(fileInfo.name, ".", suffix);
                if (name.length==(idbuf.length*2) && (suffix=="idx" || suffix=="")) {
                    auto id = hex.decode(name, idbuf);
                    if (!(id in localIdMap)) {
                        path.name = fileInfo.name;
                        path.remove();
                        bytesFreed += fileInfo.bytes;
                    }
                }
            }
        }
        log.info("Garbage collection done. {} KB freed", (bytesFreed + 512) / 1024);
    }

    /*************************************************************************
     * Save id-mappings with IdMap
     ************************************************************************/
    synchronized void saveIdMap() {
        scope map = new IdMap;
        synchronized (this) map.assets = localIdMap.values;
        foreach (meta; map.assets)
            meta.sync;
        scope tmpFile = idMapPath.dup.cat(".tmp");
        scope file = new File (tmpFile.toString, File.ReadWriteCreate);
        file.write (map.encode());
        if (usefsync) {
            version (Posix)
                fdatasync(file.fileHandle);
            else
                static assert(false, "Needs Non-POSIX implementation");
        }
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
            if (id.type in hashIdMap) {
                auto oldAsset = id.id in hashIdMap[id.type];
                if (oldAsset) { // Asset already exist
                    // Remove old asset to avoid conflict with new asset.
                    // TODO: What if old asset has id-types not covered by new asset?
                    //       or possible differing values for different hashId:s?
                    localIdMap.remove(oldAsset.localId);
                }
                hashIdMap[id.type][id.id] = asset;
            }
        }
        idMapDirty = true;
    }

    /************************************************************************************
     * Daemon-thread loop, flushing idMap periodically to disk.
     ***********************************************************************************/
    void IdMapFlusher() {
        while (idMapFlusher) {
            try if (idMapDirty) {
                garbageCollect();
                saveIdMap();
            } catch (Exception e) {
                log.error("Failed flushing IdMap with {}", e);
            }
            for (int i = 0; (i < FLUSH_INTERVAL_SEC) && idMapFlusher; i++)
                Thread.sleep(1);
        }
    }
}
