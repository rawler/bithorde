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
private import tango.math.random.Random;
private import ascii = tango.text.Ascii;
private import tango.util.log.Log;

private import lib.client;
private import lib.hashes;
private import lib.message;

private import daemon.cache.metadata;
private import daemon.cache.map;
private import daemon.client;

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

/****************************************************************************************
 * Assets throws this error when the requested segment is missing
 ***************************************************************************************/
class MissingSegmentException : Exception {
    this(char[] msg) { super(msg); }
}

enum AssetState { ALIVE, GOTIDS, DEAD }
alias void delegate(CachedAsset, AssetState) AssetLifeCycleListener;

/****************************************************************************************
 * Base for all kinds of cached assets. Provides basic reading functionality
 ***************************************************************************************/
class CachedAsset : IServerAsset {
protected:
    FilePath path;
    FilePath idxPath;
    ubyte[] _id;
    File file;
    Logger log;
    AssetMetaData _metadata;
    AssetLifeCycleListener notify;
public:
    /************************************************************************************
     * IncompleteAssetException is thrown if a not-fully-cached asset were to be Opened
     * directly as a CachedAsset
     * 
     ***********************************************************************************/
    // TODO: Should not be needed, fix cachemanager
    class IncompleteAssetException {}

    this(FilePath assetDir, ubyte[] id, AssetLifeCycleListener listener) {
        this._id = id.dup;
        this.path = assetDir.dup.append(ascii.toLower(hex.encode(id)));
        this.idxPath = path.dup.suffix(".idx");
        this.notify = listener;
        notify(this, AssetState.ALIVE);
        log = Log.lookup("daemon.cache.cachedasset."~hex.encode(id[0..4]));
    }
    ~this() {
        if (file)
            close();
    }

    /************************************************************************************
     * Assets can be created with delayed-open. Useful for CachingAsset, which needs to
     * exist when a forwarded request exists, but not create underlying files unless
     * asset is found remotely.
     ***********************************************************************************/
    void open() {
        if (idxPath.exists)
            throw new IncompleteAssetException;
        file = new File(path.toString, File.ReadExisting);
    }

    /***********************************************************************************
     * Asset is closed, unregistered, and resources closed. Afterwards, should be
     * awaiting garbage collection.
     **********************************************************************************/
    void close() {
        notify(this, AssetState.DEAD);
        if (file) {
            file.close();
            file = null;
        }
    }

    /************************************************************************************
     * Read a single segment from the Asset
     ***********************************************************************************/
    synchronized void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
        assert(file);
        ubyte[] buf = tlsBuffer(length);
        file.seek(offset);
        auto got = file.read(buf);
        auto resp = new lib.message.ReadResponse;
        resp.status = message.Status.SUCCESS;
        resp.offset = offset;
        resp.content = buf[0..got];
        cb(this, message.Status.SUCCESS, null, resp); // TODO: should really hold reference to req
    }

    /************************************************************************************
     * Adding segments is not supported for CachedAsset
     ***********************************************************************************/
    void add(ulong offset, ubyte[] data) {
        throw new IOException("Trying to write to a completed file");
    }

    /************************************************************************************
     * Find the size of the asset.
     ***********************************************************************************/
    final ulong size() {
        assert(file);
        return file.length;
    }

    AssetMetaData metadata() {
        return _metadata;
    }
    final ubyte[] id() { return _id; }

    mixin IRefCounted.Impl;
}

/****************************************************************************************
 * WriteableAsset implements uploading to Assets, and forms a base for CachingAsset
 ***************************************************************************************/
class WriteableAsset : CachedAsset {
protected:
    CacheMap cacheMap;
    Digest[HashType] hashes;
    uint hashingptr;
public:
    /************************************************************************************
     * Create WriteableAsset, id will be auto-random-generated if not specified.
     ***********************************************************************************/
    this(FilePath assetDir, AssetLifeCycleListener _listener) {
        auto id = new ubyte[32];
        rand.randomizeUniform!(ubyte[],false)(id);
        this(assetDir, id, _listener);
    }
    this(FilePath assetDir, ubyte[] id, AssetLifeCycleListener _listener) { /// ditto
        foreach (k,hash; HashMap)
            hashes[hash.pbType] = hash.factory();
        super(assetDir, id, _listener);
        log = Log.lookup("daemon.cache.writeasset."~hex.encode(id[0..4]));
    }

    /************************************************************************************
     * Create new writeable asset and prepare for writing
     ***********************************************************************************/
    void create(ulong size)
    in { assert(size > 0); } // Zero-assets are not supported
    body {
        cacheMap = new CacheMap(idxPath);
        file = new File(path.toString, File.Style(File.Access.ReadWrite, File.Open.New));
        file.truncate(size);
    }

    /************************************************************************************
     * Regular opening for reading
     ***********************************************************************************/
    void open() {
        cacheMap = new CacheMap(idxPath);
        super.open();
    }

    synchronized void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
        if (!cacheMap || cacheMap.has(offset, length))
            super.aSyncRead(offset, length, cb);
        else
            throw new MissingSegmentException("Missing requested segment");
    }

    /************************************************************************************
     * Add a data-segment to the asset, and update the CacheMap
     ***********************************************************************************/
    synchronized void add(ulong offset, ubyte[] data) {
        if (!cacheMap)
            throw new IOException("Trying to write to a completed file");
        file.seek(offset);
        file.write(data);
        cacheMap.add(offset, data.length);
        updateHashes();
    }
protected:
    /************************************************************************************
     * Check if more data is available for hashing
     ***********************************************************************************/
    void updateHashes() {
        auto zeroBlockSize = cacheMap.zeroBlockSize;
        if (zeroBlockSize > hashingptr) {
            scope auto newdata = new ubyte[zeroBlockSize - hashingptr];
            file.seek(hashingptr);
            auto read = file.read(newdata);
            assert(read == newdata.length);
            foreach (hash; hashes) {
                hash.update(newdata);
            }
            if (zeroBlockSize == file.length)
                finish();
            else
                hashingptr = zeroBlockSize;
        }
    }

    /************************************************************************************
     * Post-finish hooks. Finalize the digests, add to assetMap, and remove the CacheMap
     ***********************************************************************************/
    void finish() {
        assert(cacheMap.segcount == 1);
        assert(cacheMap.assetSize == file.length);
        log.trace("Asset complete");
        _metadata = new AssetMetaData;
        _metadata.localId = _id.dup;

        foreach (type, hash; hashes) {
            auto digest = hash.binaryDigest;
            auto hashId = new message.Identifier;
            hashId.type = type;
            hashId.id = digest.dup;
            _metadata.hashIds ~= hashId;
        }

        notify(this, AssetState.GOTIDS);

        cacheMap.path.remove();
        delete cacheMap;
    }
}

/****************************************************************************************
 * CachingAsset is an important workhorse in the entire system. Implements a currently
 * caching asset, still not completely locally available.
 ***************************************************************************************/
class CachingAsset : WriteableAsset {
    BHServerOpenCallback cb;
    IServerAsset remoteAsset;
    message.Identifier[] reqHashIds;
public:
    this (FilePath assetDir, BHServerOpenCallback cb, message.Identifier[] reqHashIds, AssetLifeCycleListener _listener) {
        this.cb = cb;
        this.reqHashIds = reqHashIds;
        super(assetDir, _listener);
        log = Log.lookup("daemon.cache.cachingasset."~hex.encode(id[0..4]));
    }

    /************************************************************************************
     * Callback for backing remoteAssets. Recieves openResponses for attempted opens
     ***********************************************************************************/
    void remoteCallback(IServerAsset remoteAsset, message.Status status) {
        if (remoteAsset && (status == message.Status.SUCCESS)) {
            this.remoteAsset = remoteAsset;
            create(remoteAsset.size);
            log.trace("Caching remoteAsset of size {}", size);

            _metadata = new AssetMetaData;
            _metadata.localId = id;
            _metadata.hashIds = reqHashIds;
            notify(this, AssetState.GOTIDS);
        }
        cb(this, status);
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
    void finish() {
        // TODO: Validate hashId:s
        super.finish();
        remoteAsset.unRef();
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
            try {
                realRead(offset, length, cb);
            } catch (MissingSegmentException e) {
                remoteAsset.aSyncRead(offset, length, &callback);
            }
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
        }
    }
}

