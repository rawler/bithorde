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
private import tango.io.device.File;
private import tango.io.FilePath;
version (Posix) private import tango.stdc.posix.unistd;
private import ascii = tango.text.Ascii;
private import tango.util.log.Log;

private import lib.client;
private import lib.hashes;
private import lib.message;

private import daemon.cache.metadata;
private import daemon.cache.map;
private import daemon.client;

const LOCALID_LENGTH = 32;

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

/****************************************************************************************
 * Base for all kinds of cached assets. Provides basic reading functionality
 ***************************************************************************************/
class BaseAsset : private File, public IServerAsset {
protected:
    FilePath path;
    FilePath idxPath;
    Logger log;
    AssetMetaData _metadata;
    HashIdsListener updateHashIds;
public:
    /************************************************************************************
     * IncompleteAssetException is thrown if a not-fully-cached asset were to be Opened
     * directly as a BaseAsset
     ***********************************************************************************/
    this(FilePath path, AssetMetaData metadata, HashIdsListener updateHashIds) {
        this(path, metadata, File.ReadExisting, updateHashIds);
        assert(!idxPath.exists);
    }
    protected this(FilePath path, AssetMetaData metadata, File.Style style, HashIdsListener updateHashIds) {
        this.path = path;
        this.idxPath = path.dup.suffix(".idx");
        this.updateHashIds = updateHashIds;
        this._metadata = metadata;
        log = Log.lookup("daemon.cache.baseasset."~path.name[0..8]);

        super(path.toString, style);
    }

    /************************************************************************************
     * Asset is closed, unregistered, and resources closed. Afterwards, should be
     * awaiting garbage collection.
     ***********************************************************************************/
    void close() {
        super.close();
    }

    /************************************************************************************
     * Implements IServerAsset.hashIds()
     * TODO: IServerAsset perhaps should be migrated to MetaData?
     ***********************************************************************************/
    Identifier[] hashIds() {
        if (_metadata)
            return _metadata.hashIds;
        else
            return null;
    }

    /************************************************************************************
     * Read a single segment from the Asset
     ***********************************************************************************/
    synchronized void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
        ubyte[] buf = tlsBuffer(length);
        version (Posix) { // Posix has pread() for atomic seek+read
            auto got = pread(fileHandle, buf.ptr, length, offset);
        } else {
            seek(offset);
            auto got = read(buf);
        }
        auto resp = new lib.message.ReadResponse;
        if (got == Eof) {
            resp.status = message.Status.NOTFOUND;
        } else {
            resp.status = message.Status.SUCCESS;
            resp.offset = offset;
            resp.content = buf[0..got];
        }
        cb(this, message.Status.SUCCESS, null, resp); // TODO: should really hold reference to req
    }

    /************************************************************************************
     * Adding segments is not supported for BaseAsset
     ***********************************************************************************/
    void add(ulong offset, ubyte[] data) {
        throw new IOException("Trying to write to a completed file");
    }

    /************************************************************************************
     * Find the size of the asset.
     ***********************************************************************************/
    final ulong size() {
        return length;
    }
}

/****************************************************************************************
 * WriteableAsset implements uploading to Assets, and forms a base for CachingAsset
 ***************************************************************************************/
class WriteableAsset : BaseAsset {
protected:
    CacheMap cacheMap;
    Digest[HashType] hashes;
    ulong hashedPtr;
public:
    /************************************************************************************
     * Create WriteableAsset by path and size
     ***********************************************************************************/
    this(FilePath path, AssetMetaData metadata, ulong size, HashIdsListener updateHashIds) {
        this(path, metadata, File.Style(File.Access.ReadWrite, File.Open.Sedate), updateHashIds); // Super-class opens underlying file
        truncate(size);           // We resize it to right size
    }
    protected this(FilePath path, AssetMetaData metadata, File.Style style, HashIdsListener updateHashIds) { /// ditto
        foreach (k,hash; HashMap)
            hashes[hash.pbType] = hash.factory();
        super(path, metadata, style, updateHashIds);
        cacheMap = new CacheMap(idxPath);
        log = Log.lookup("daemon.cache.writeasset."~path.name[0..8]);
    }

    synchronized void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
        assert(!this.cacheMap || this.cacheMap.has(offset, length), "Checking cacheMap expected before aSyncRead");
        super.aSyncRead(offset, length, cb);
    }

    /************************************************************************************
     * Add a data-segment to the asset, and update the CacheMap
     ***********************************************************************************/
    synchronized void add(ulong offset, ubyte[] data) {
        if (!cacheMap)
            throw new IOException("Trying to write to a completed file");
        version (Posix) { // Posix has pwrite() for atomic write+seek
            auto written = pwrite(fileHandle, data.ptr, data.length, offset);
        } else {
            seek(offset);
            auto written = write(data);
        }
        cacheMap.add(offset, data.length);
        updateHashes();
    }
protected:
    /************************************************************************************
     * Check if more data is available for hashing
     ***********************************************************************************/
    void updateHashes() {
        auto zeroBlockSize = cacheMap.zeroBlockSize;
        if (zeroBlockSize > hashedPtr) {
            auto bufsize = zeroBlockSize - hashedPtr;
            auto buf = tlsBuffer(bufsize);
            auto got = pread(fileHandle, buf.ptr, bufsize, hashedPtr);
            assert(got == bufsize);
            foreach (hash; hashes) {
                hash.update(buf[0..bufsize]);
            }
            if (zeroBlockSize == length)
                finish();
            else
                hashedPtr = zeroBlockSize;
        }
    }

    /************************************************************************************
     * Post-finish hooks. Finalize the digests, add to assetMap, and remove the CacheMap
     ***********************************************************************************/
    void finish() {
        assert(updateHashIds);
        assert(cacheMap);
        assert(cacheMap.segcount == 1);
        assert(cacheMap.assetSize == length);
        log.trace("Asset complete");

        auto hashIds = new message.Identifier[hashes.length];
        uint i;
        foreach (type, hash; hashes) {
            auto digest = hash.binaryDigest;
            auto hashId = new message.Identifier;
            hashId.type = type;
            hashId.id = digest.dup;
            hashIds[i++] = hashId;
        }

        updateHashIds(hashIds);

        cacheMap.path.remove();
        delete cacheMap;
    }
}

/****************************************************************************************
 * CachingAsset is an important workhorse in the entire system. Implements a currently
 * caching asset, still not completely locally available.
 ***************************************************************************************/
class CachingAsset : WriteableAsset {
    IServerAsset remoteAsset;
public:
    this (FilePath path, AssetMetaData metadata, IServerAsset remoteAsset, HashIdsListener updateHashIds) {
        this.remoteAsset = remoteAsset;
        super(path, metadata, remoteAsset.size, updateHashIds); // TODO: Verify remoteAsset.size against local file
        log = Log.lookup("daemon.cache.cachingasset." ~ path.name[0..8]);
        log.trace("Caching remoteAsset of size {}", size);
    }

    synchronized void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
        auto r = new ForwardedRead;
        r.offset = offset;
        r.length = length;
        r.cb = cb;
        r.tryRead();
    }
protected:
    /************************************************************************************
     * Triggered when the underlying cache is complete.
     ***********************************************************************************/
    void finish() body {
        // TODO: Validate hashId:s
        super.finish();
        remoteAsset = null;
    }
private:
    void realRead(ulong offset, uint length, BHReadCallback cb) {
        super.aSyncRead(offset, length, cb);
    }

    /************************************************************************************
     * Every read-operation for non-cached data results in a ForwardedRead, which tracks
     * a forwarded ReadRequest, recieves the response, and updates the CachingAsset.
     ***********************************************************************************/
    class ForwardedRead {
        ulong offset;
        uint length;
        BHReadCallback cb;
        message.Status lastStatus;
        // TODO: Limit re-tries

        void tryRead() {
            if (!cacheMap || cacheMap.has(offset, length)) {
                realRead(offset, length, cb);
                delete this;
            } else
                remoteAsset.aSyncRead(offset, length, &callback);
        }
        void callback(IAsset asset, message.Status status, message.ReadRequest req, message.ReadResponse resp) {
            if (status == message.Status.SUCCESS) {
                if (cacheMap) // May no longer be open for writing, due to stale requests
                    add(resp.offset, resp.content);
                tryRead();
            } else if ((status == message.Status.DISCONNECTED) && (status != lastStatus)) { // Hackish. We may have double-requested the same part of the file, so attempt to read it anyways
                lastStatus = status;
                tryRead();
            } else {
                // TODO: Report back error
            }
            delete req;
        }
    }
}

