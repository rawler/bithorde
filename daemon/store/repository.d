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

module daemon.store.repository;

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
private import tango.util.MinMax;

static if ( !is(typeof(fdatasync) == function ) )
    extern (C) int fdatasync(int);

private import lib.asset;
static private import base32 = lib.base32;
private import lib.hashes;
private import lib.httpserver;
private import lib.protobuf;
private import lib.pumping;

private import daemon.store.asset;
private import daemon.store.storedasset;
private import daemon.client;
private import daemon.config;
private import daemon.refcount;

const K = 1024;
const MAX_READ_CHUNK = 64 * K;

const FLUSH_INTERVAL_SEC = 30;

const ADVICE_CONCURRENT_READ = 6;

/****************************************************************************************
 * A repository of assets linked in the filesystem.
 * Each repository is assigned a root-directory, and stores it's id-mappings in .bhIdMap
 ***************************************************************************************/
class Repository : IAssetSource {
    class Asset : daemon.store.asset.BaseAsset, IServerAsset, ProtoBufMessage {
        mixin IAsset.StatusSignal;
        mixin RefCountTarget;

        mixin(PBField!(char[], "path"));            /// Path to the asset
        mixin(PBField!(ulong, "mtime"));            /// Time of Last validated version
        mixin ProtoBufCodec!(PBMapping("path",      1),
                             PBMapping("hashIds",   2),
                             PBMapping("mtime",     3),
                             PBMapping("size",      4));

        private IStoredAsset _stored;
        private ulong _mtimeOfHashStart;

        bool isValid() {
            auto path = assetPath;
            return path.exists 
                    && path.fileSize == this.size
                    && (path.modified - Time.epoch1970).seconds == this.mtime;
        }

        void rehash() {
            auto path = assetPath;
            size = path.fileSize;
            _mtimeOfHashStart = (path.modified - Time.epoch1970).seconds;
            log.trace("Running rehash on {}", path.toString );
            _stored = new RehashingAsset(path, size, &updateHashIds);
        }

        private void ensureOpen() {
            if (!sizeIsSet)
                size = assetPath.fileSize;
            if (!_stored)
                _stored = new CompleteAsset(assetPath);
        }

        bool isOpen() {
            return _stored || refs.length > 0;
        }

        bool isHashing() {
            return cast(RehashingAsset)_stored !is null;
        }

        void close() {
            if (_stored) {
                _stored.close();
                _stored = null;
            }
        }

        void aSyncRead(ulong offset, uint _length, BHReadCallback cb) {
            void respond(message.Status status, ubyte[] result=null) {
                scope resp = new lib.message.ReadResponse;
                resp.status = status;
                if (result.ptr) {
                    resp.offset = offset;
                    resp.content = result;
                }
                cb(resp.status, null, resp); // TODO: track read-request
            }
            ensureOpen;

            ubyte[MAX_READ_CHUNK] _buf;
            auto buf = _buf[0..min!(uint)(_length, _buf.length)];
            ulong missing;

            auto result = _stored.readChunk(offset, buf, missing);
            if (missing)
                respond(message.Status.NOTFOUND, result);
            else
                respond(message.Status.SUCCESS, result);
        }

        message.Identifier[] hashIds() {
            return super.hashIds();
        }
        message.Identifier[] hashIds(message.Identifier[] ids) {
            return super.hashIds(ids);
        }

        FilePath assetPath() {
            return root.dup.append(path);
        }

        private void updateHashIds(message.Identifier[] ids) {
            this.hashIds = ids;
            pump.queueCallback(&notifyHashUpdate);
        }

        private void notifyHashUpdate() {
            close();
            addToIdMap(this);
            mtime = _mtimeOfHashStart;

            _statusSignal.call(this, message.Status.SUCCESS, null);
        }

        char[] magnetLink() {
            return formatMagnet(hashIds, size);
        }
    }

protected:
    FilePath idMapPath;
    bool idMapDirty;

    Asset hashIdMap[message.HashType][ubyte[]];
    Asset assetMap[char[]];

    Thread idMapFlusher;
    bool usefsync;
    Pump pump;

    static Logger log;
    static this() {
        log = Log.lookup("daemon.store.repository");
    }
public:
    FilePath root;

    /************************************************************************************
     * Create a CacheManager with a given asset-directory and underlying Router-instance
     ***********************************************************************************/
    this(Pump pump, FilePath root, bool usefsync) {
        if (!(root.exists && root.isFolder && root.isWritable))
            throw new ConfigException(root.toString ~ " must be an existing writable directory");
        this.root = root.dup;
        this.pump = pump;
        this.usefsync = usefsync;

        hashIdMap[message.HashType.SHA1] = null;
        hashIdMap[message.HashType.SHA256] = null;
        hashIdMap[message.HashType.TREE_TIGER] = null;
        hashIdMap[message.HashType.ED2K] = null;

        idMapPath = root.dup.append(".bhIdMap");
        if (idMapPath.exists) {
            try {
                loadIdMap();
            } catch (DecodeException) {
                log.fatal("Failed to load the old idMap. Assets will need to be re-added.");
            }
        }
    }

    /************************************************************************************
     * Tries to find assetMetaData for specified hashIds. First match applies.
     ***********************************************************************************/
    Asset findMetaAsset(message.Identifier[] hashIds) {
        log.trace("Looking for {}", formatMagnet(hashIds, 0));
        foreach (id; hashIds) {
            if ((id.type in hashIdMap) && (id.id in hashIdMap[id.type]))
                return hashIdMap[id.type][id.id];
        }
        return null;
    }

    /************************************************************************************
     * Gets the size held in this repository, in bytes.
     ***********************************************************************************/
    ulong size() {
        ulong retval;

        foreach (asset; assetMap)
            retval += asset.size;

        return retval;
    }

    /************************************************************************************
     * Expose the number of assets in cache
     ***********************************************************************************/
    uint assetCount() {
        return assetMap.length;
    }

    /************************************************************************************
     * Final startup preparation
     ***********************************************************************************/
    void start() {
        scanForChanges();

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

    /*************************************************************************************
     * Clears an asset of known hashIds
     ************************************************************************************/
    synchronized void forgetHashIds(Asset asset) {
        foreach (hashId; asset.hashIds) {
            if ((hashId.type in hashIdMap) &&
                (hashId.id in hashIdMap[hashId.type]) &&
                (hashIdMap[hashId.type][hashId.id] == asset))
                hashIdMap[hashId.type].remove(hashId.id);
        }
        asset.hashIds = null;
        idMapDirty = true;
    }

    /*************************************************************************************
     * Remove a references to an asset.
     ************************************************************************************/
    synchronized long removeAsset(Asset asset) {
        log.info("Removing link to {}", asset.assetPath.toString);

        if (asset.path in assetMap)
            assetMap.remove(asset.path);
        forgetHashIds(asset);

        return asset.size;
    }

    /************************************************************************************
     * Implements IAssetSource.findAsset. Tries to get a hold of a certain asset.
     ***********************************************************************************/
    bool findAsset(BindRead req) {
        auto asset = findMetaAsset(req.ids);
        if (asset && asset.isValid) {
            log.trace("serving {} from repository", asset.assetPath.toString);
            req.callback(asset, message.Status.SUCCESS, null);
            return true;
        } else {
            return false;
        }
    }

    /************************************************************************************
     * Implement uploading new assets to this Cache.
     ***********************************************************************************/
    void uploadAsset(char[] path, BHAssetStatusCallback callback) {
        try {
            auto fullpath = root.dup.append(path.dup);
            if (fullpath.exists) {
                scope f = new File(fullpath.toString);
                auto asset = new Asset();
                asset.path = path.dup;

                addToIdMap(asset);
                asset.attachWatcher(callback);
                callback(asset, message.Status.SUCCESS, null);
                scanForChanges; // TODO: should maybe be run out-of-eventloop, or just for new asset?
            } else {
                log.error("BindWrite linking non-existing file '{}'", path);
                callback(null, message.Status.NOTFOUND, null);
            }
        } catch (IOException e) {
            log.error("While opening upload asset: {}", e);
            callback(null, message.Status.NOTFOUND, null);
        }
    }

    /************************************************************************************
     * Handles incoming management-requests
     ***********************************************************************************/
/+  TODO  MgmtEntry[] onManagementRequest(char[][] path) {
        MgmtEntry[] res;
        foreach (asset; assetMap) {
            auto assetOpen = asset.isOpen ? "open" : "closed";
            auto desc = assetOpen ~ ", " ~ asset.magnetLink;
            res ~= MgmtEntry(hex.encode(asset.localId), desc);
        }
        return res;
    }+/
private:
    /*************************************************************************
     * The IdMap is a dummy-object for storing the mapping between hashIds
     * and localIds.
     ************************************************************************/
    class IdMap { // TODO: Re-work protobuf-lib so it isn't needed
        mixin(PBField!(Asset[], "assets"));
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
            asset.path = asset.path.dup;
            assetMap[asset.path] = asset;
            foreach (id; asset.hashIds) {
                id.id = id.id.dup;
                hashIdMap[id.type][id.id] = asset;
            }
        }
        idMapDirty = false;
    }

    /************************************************************************************
     * Walks through assets Repository, purging those no longer found, and initiating
     * rescan of those not matching their cached size and mtime.
     ***********************************************************************************/
    synchronized void scanForChanges() {
        debug (Performance) {
            Time started = Clock.now;
            scope(exit) { log.trace("Repository-scan took {}ms",(Clock.now-started).millis); }
        }

        ulong bytesFreed;
        auto openCount = 0;
        scope Asset[] staleAssets;
        foreach (asset; assetMap) {
            auto path = asset.assetPath;
            if (!asset.isValid)
                staleAssets ~= asset;
            if (asset.isOpen)
                openCount++;
        }
        foreach (asset; staleAssets) {
            if (asset.assetPath.exists) {
                if (!asset.isHashing && openCount++ < ADVICE_CONCURRENT_READ)
                    asset.rehash();
            } else {
                auto res = removeAsset(asset);
                if (res >= 0)
                    bytesFreed += res;
            }
        }
        if (bytesFreed)
            log.info("Removed {}KB of missing assets", (bytesFreed + 512) / 1024);
    }

    /*************************************************************************
     * Save id-mappings with IdMap
     ************************************************************************/
    synchronized void saveIdMap() {
        scope map = new IdMap;
        synchronized (this) map.assets = assetMap.values;
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
    synchronized void addToIdMap(Asset asset) {
        log.trace("Committing {} ({}) to map", asset.assetPath.toString, asset.magnetLink);

        foreach (id; asset.hashIds) {
            if (id.type in hashIdMap) {
                auto oldAsset = id.id in hashIdMap[id.type];
                if (oldAsset && oldAsset.path != asset.path) { // Asset already exist
                    // Remove old asset to avoid conflict with new asset.
                    // TODO: What if old asset has id-types not covered by new asset?
                    //       or possible differing values for different hashId:s?
                    removeAsset(*oldAsset);
                }
                hashIdMap[id.type][id.id] = asset;
            }
        }
        assetMap[asset.path] = asset;
        idMapDirty = true;
    }

    /************************************************************************************
     * Daemon-thread loop, flushing idMap periodically to disk.
     ***********************************************************************************/
    void IdMapFlusher() {
        while (idMapFlusher) {
            try {
                scanForChanges();
                if (idMapDirty)
                    saveIdMap();
            } catch (Exception e) {
                log.error("Failed flushing IdMap with {}", e);
            }
            for (int i = 0; (i < FLUSH_INTERVAL_SEC) && idMapFlusher; i++)
                Thread.sleep(1);
        }
    }
}
