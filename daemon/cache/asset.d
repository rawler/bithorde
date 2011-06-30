/****************************************************************************************
 * All the different variants of Cache-Assets
 *
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
module daemon.cache.asset;

private import tango.core.Exception;
private import tango.core.Thread;
private import tango.core.Signal;
private import tango.core.WeakRef;
private import tango.io.device.File;
private import tango.io.FilePath;
private import ascii = tango.text.Ascii;
private import tango.util.log.Log;
private import tango.time.Clock;
private import tango.time.Time;

private import lib.client;
private import lib.hashes;
private import lib.digest.stateful;
private import lib.message;

private import daemon.cache.metadata;
private import daemon.cache.map;
private import daemon.client;

version (Posix) {
    private import tango.stdc.posix.unistd;
    static if ( !is(typeof(fdatasync) == function ) )
        extern (C) int fdatasync(int);
} else {
    static assert(false, "fdatasync Needs Non-POSIX implementation");
}

const LOCALID_LENGTH = 32;
const Hashers = [HashType.TREE_TIGER];

private static ThreadLocal!(ubyte[]) tls_buf;
private static this() {
    tls_buf = new ThreadLocal!(ubyte[]);
}
private static ubyte[] tlsBuffer(uint size) {
    auto buf = tls_buf.val;
    if (buf == (ubyte[]).init) {
        buf = new ubyte[size];
        tls_buf.val = buf;
    } else if (size > buf.length) {
        buf.length = size;
    }
    return buf;
}

alias void delegate(Identifier[]) HashIdsListener;

interface IAssetData {
    void aSyncRead(ulong offset, uint length, BHReadCallback);
    ulong size();
    void close();
}

/*****************************************************************************************
 * Class for file with stateless read/write. I/E no need for the user to care about
 * read/write position.
 ****************************************************************************************/
class StatelessFile : File {
    /*************************************************************************************
     * Reads as many bytes as possible into dst, and returns the amount.
     ************************************************************************************/
    ssize_t pRead(ulong pos, void[] dst) {
        version (Posix) { // Posix has pread() for atomic seek+read
            ssize_t got = pread(fileHandle, dst.ptr, dst.length, pos);
            if (got is -1)
                error;
            else
               if (got is 0 && dst.length > 0)
                   return Eof;
            return got;
        } else synchronized (this) {
            seek(pos);
            return read(buf);
        }
    }

    /*************************************************************************************
     * Reads as many bytes as possible into buf, and returns the amount.
     ************************************************************************************/
    ssize_t pWrite(ulong pos, void[] src) {
        version (Posix) { // Posix has pwrite() for atomic write+seek
            ssize_t written = pwrite(fileHandle, src.ptr, src.length, pos);
            if (written is -1)
                error;
            return written;
        } else synchronized (this) {
            seek(pos);
            return write(data);
        }
    }
}

/*****************************************************************************************
 * Base for all kinds of cached assets. Provides basic reading functionality
 ****************************************************************************************/
class BaseAsset : private StatelessFile, public IAssetData {
protected:
    FilePath path;
    FilePath idxPath;
    Logger log;
    AssetMetaData _metadata;
    ulong _size;
public:
    /*************************************************************************************
     * IncompleteAssetException is thrown if a not-fully-cached asset were to be Opened
     * directly as a BaseAsset
     ************************************************************************************/
    this(FilePath path, AssetMetaData metadata) {
        this.path = path;
        this.idxPath = path.dup.suffix(".idx");
        this._metadata = metadata;
        log = Log.lookup("daemon.cache.baseasset."~path.name[0..8]);

        super();
        assetOpen(path);
        this._size = length;
    }

    /*************************************************************************************
     * assetOpen - Overridable function to really open or create the asset.
     ************************************************************************************/
    void assetOpen(FilePath path) {
        File.open(path.toString);
    }

    /*************************************************************************************
     * Asset is closed, unregistered, and resources closed. Afterwards, should be
     * awaiting garbage collection.
     ************************************************************************************/
    void close() {
        super.close();
    }

    /*************************************************************************************
     * Implements IServerAsset.hashIds()
     * TODO: IServerAsset perhaps should be migrated to MetaData?
     ************************************************************************************/
    Identifier[] hashIds() {
        if (_metadata)
            return _metadata.hashIds;
        else
            return null;
    }

    /*************************************************************************************
     * Read a single segment from the Asset
     ************************************************************************************/
    synchronized void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
        ubyte[] buf = tlsBuffer(length);
        auto _length = length; // Avoid scope-problems for next line
        auto got = pRead(offset, buf[0.._length]);
        auto resp = new lib.message.ReadResponse;
        if (got == 0 || got == Eof) {
            resp.status = message.Status.NOTFOUND;
        } else {
            _metadata.noteInterest(Clock.now, (cast(double)got)/cast(double)size);
            resp.status = message.Status.SUCCESS;
            resp.offset = offset;
            resp.content = buf[0..got];
        }
        cb(resp.status, null, resp); // TODO: should really hold reference to req
    }

    /*************************************************************************************
     * Adding segments is not supported for BaseAsset
     ************************************************************************************/
    void add(ulong offset, ubyte[] data) {
        throw new IOException("Trying to write to a completed file");
    }

    /*************************************************************************************
     * Find the size of the asset.
     ************************************************************************************/
    final ulong size() {
        return _size;
    }
}

/*****************************************************************************************
 * WriteableAsset implements uploading to Assets, and forms a base for CachingAsset and
 * UploadAsset
 ****************************************************************************************/
class WriteableAsset : BaseAsset {
protected:
    CacheMap cacheMap;
    IStatefulDigest[HashType] hashers;
    ulong hashedPtr;
    HashIdsListener updateHashIds;
    bool usefsync;
public:
    /*************************************************************************************
     * Create WriteableAsset by path and size
     ************************************************************************************/
    this(FilePath path, AssetMetaData metadata, ulong size,
         HashIdsListener updateHashIds, bool usefsync) {
        resetHashes();
        this.updateHashIds = updateHashIds;
        this.usefsync = usefsync;
        super(path, metadata); // Parent calls open()
        truncate(size);           // We resize it to right size
        _size = size;
        log = Log.lookup("daemon.cache.writeasset."~path.name[0..8]); // TODO: fix order and double-init
    }

    /*************************************************************************************
     * Init hashing from offset zero and with clean state.
     ************************************************************************************/
    private void resetHashes() {
        hashers = null;
        hashedPtr = 0;
        foreach (type; Hashers) {
            auto factory = HashMap[type].factory;
            if (factory)
                hashers[type] = factory();
        }
    }

    /*************************************************************************************
     * Create and open a WriteableAsset. Make sure to create cacheMap first, create the
     * file, and then truncate it to the right size.
     ************************************************************************************/
    void assetOpen(FilePath path) {
        if (idxPath.exists && !path.exists)
            idxPath.remove();
        scope idxFile = new File(idxPath.toString, File.Style(File.Access.Read, File.Open.Create));
        cacheMap = new CacheMap();
        cacheMap.load(idxFile);
        hashedPtr = cacheMap.header.hashedAmount;
        foreach (type, hasher; hashers) {
            if (type in cacheMap.header.hashes) {
                hasher.load(cacheMap.header.hashes[type]);
            } else {
                if (hashedPtr != 0)
                    log.warn("Missing {} in stored hashState. Forced-reset, will trigger blocking rehash.", HashMap[type]);
                resetHashes();
                break;
            }
        }
        File.open(path.toString, File.Style(File.Access.ReadWrite, File.Open.Sedate));
    }

    /*************************************************************************************
     * Asynchronous read, first checking the cacheMap has the block we're looking for.
     ************************************************************************************/
    synchronized void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
        if (length == 0) {
            cb(message.Status.SUCCESS, null, null);
        } else if (this.cacheMap && !this.cacheMap.has(offset, length)) {
            cb(message.Status.NOTFOUND, null, null);
        } else {
            super.aSyncRead(offset, length, cb);
        }
    }

    /*************************************************************************************
     * Add a data-segment to the asset, and update the CacheMap
     ************************************************************************************/
    void add(ulong offset, ubyte[] data) {
        if (!cacheMap)
            throw new IOException("Trying to write to a completed file");
        synchronized (this) {
            auto written = pWrite(offset, data);
            if (written != data.length)
                throw new IOException("Failed to write received segment. Disk full?");
            cacheMap.add(offset, written);
        }
        updateHashes();
    }

    /*************************************************************************************
     * Make sure to synchronize asset data, and flush cachemap to disk.
     * Params:
     *   usefsync = control whether fsync is used, or simply flushing to filesystem is
     *              enough
     ************************************************************************************/
    void sync() {
        scope CacheMap cmapToWrite;
        synchronized (this) {
            if (cacheMap) {
                // TODO: Refactor this
                cacheMap.header.hashedAmount = hashedPtr;
                foreach (type, hasher; hashers) {
                    auto buf = new ubyte[hasher.maxStateSize];
                    cacheMap.header.hashes[type] = hasher.save(buf);
                }
                cmapToWrite = new CacheMap(cacheMap);
            }
        }
        if (usefsync)
            fdatasync(fileHandle);

        if (cmapToWrite) {
            auto tmpPath = idxPath.dup.cat(".new");
            scope idxFile = new File(tmpPath.toString, File.WriteCreate);
            cmapToWrite.write(idxFile);
            if (usefsync)
                fdatasync(idxFile.fileHandle);

            idxFile.close();
            tmpPath.rename(idxPath);
        }
    }
protected:
    /*************************************************************************************
     * Check if more data is available for hashing
     ************************************************************************************/
    void updateHashes() {
        auto zeroBlockSize = cacheMap.zeroBlockSize;
        if (zeroBlockSize > hashedPtr) {
            auto bufsize = zeroBlockSize - hashedPtr;
            auto buf = tlsBuffer(bufsize);
            auto got = pRead(hashedPtr, buf[0..bufsize]);
            assert(got == bufsize);
            foreach (hash; hashers) {
                hash.update(buf[0..bufsize]);
            }
            if (zeroBlockSize == _size)
                finish();
            else
                hashedPtr = zeroBlockSize;
        }
    }

    /*************************************************************************************
     * Post-finish hooks. Finalize the digests, add to assetMap, and remove the CacheMap
     ************************************************************************************/
    void finish() {
        assert(updateHashIds);
        assert(cacheMap);
        assert(cacheMap.segcount == 1);
        assert(cacheMap.assetSize == length);
        log.trace("Asset complete");

        auto hashIds = new message.Identifier[hashers.length];
        synchronized (this) {
            uint i;
            foreach (type, hash; hashers) {
                auto digest = hash.binaryDigest;
                auto hashId = new message.Identifier;
                hashId.type = type;
                hashId.id = digest.dup;
                hashIds[i++] = hashId;
            }

            cacheMap = null;
            sync();
            idxPath.remove();
        }

        updateHashIds(hashIds);
    }
}

/*****************************************************************************************
 * Assets in the "upload"-phase.
 ****************************************************************************************/
class UploadAsset : WriteableAsset {
    this(FilePath path, AssetMetaData metadata, ulong size,
         HashIdsListener updateHashIds, bool usefsync) {
        super(path, metadata, size, updateHashIds, usefsync);
    }

    /*************************************************************************************
     * UploadAssets will have zero-rating until they are complete. When complete, set
     * to max.
     ************************************************************************************/
    void finish() {
        _metadata.setMaxRating(Clock.now);
        super.finish();
    }
}

/*****************************************************************************************
 * CachingAsset is an important workhorse in the entire system. Implements a currently
 * caching asset, still not completely locally available.
 ****************************************************************************************/
class CachingAsset : WriteableAsset {
    IServerAsset remoteAsset;
public:
    this (FilePath path, AssetMetaData metadata, IServerAsset remoteAsset,
          HashIdsListener updateHashIds, bool usefsync) {
        this.remoteAsset = remoteAsset;
        remoteAsset.takeRef(this);
        remoteAsset.attachWatcher(&metadata.onBackingUpdate);
        super(path, metadata, remoteAsset.size, updateHashIds, usefsync); // TODO: Verify remoteAsset.size against local file
        log = Log.lookup("daemon.cache.cachingasset." ~ path.name[0..8]);
        log.trace("Caching remoteAsset of size {}", size);
    }

    void close() {
        closeUpstream();
        super.close();
    }

    synchronized void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
        auto r = new ForwardedRead;
        r.offset = offset;
        r.length = length;
        r.cb = cb;
        r.tryRead();
    }
protected:
    /*************************************************************************************
     * Triggered when the underlying cache is complete.
     ************************************************************************************/
    void finish() body {
        // TODO: Validate hashId:s
        super.finish();
        closeUpstream();
    }
private:
    void closeUpstream() {
        if (remoteAsset) {
            remoteAsset.detachWatcher(&_metadata.onBackingUpdate);
            remoteAsset.dropRef(this);
            remoteAsset = null;
        }
    }

    void realRead(ulong offset, uint length, BHReadCallback cb) {
        super.aSyncRead(offset, length, cb);
    }

    /*************************************************************************************
     * Every read-operation for non-cached data results in a ForwardedRead, which tracks
     * a forwarded ReadRequest, recieves the response, and updates the CachingAsset.
     ************************************************************************************/
    class ForwardedRead {
        ulong offset;
        uint length;
        BHReadCallback cb;
        message.Status lastStatus;
        uint tries;

        void tryRead() {
            if (!cacheMap || cacheMap.has(offset, length)) {
                realRead(offset, length, cb);
                delete this;
            } else if (tries++ < 4) {
                remoteAsset.aSyncRead(offset, length, &callback);
            } else {
                fail();
            }
        }
        void fail() {
            auto resp = new lib.message.ReadResponse;
            resp.status = message.Status.NOTFOUND;
            cb(resp.status, null, resp);
        }
        void callback(message.Status status, message.ReadRequest req, message.ReadResponse resp) {
            if (status == message.Status.SUCCESS && resp && resp.content.length) {
                if (cacheMap) // May no longer be open for writing, due to stale requests
                    add(resp.offset, resp.content);
                tryRead();
            } else if ((status == message.Status.DISCONNECTED) && (status != lastStatus)) { // Hackish. We may have double-requested the same part of the file, so attempt to read it anyways
                lastStatus = status;
                tryRead();
            } else {
                log.warn("Failed forwarded read, with error {}", status);
                fail();
            }
            delete req;
        }
    }
}

