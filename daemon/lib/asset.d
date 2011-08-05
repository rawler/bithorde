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
module daemon.lib.asset;

private import tango.core.Exception;
private import tango.core.Thread;
private import tango.core.sync.Semaphore;
private import tango.core.Signal;
private import tango.io.device.File;
private import tango.io.FilePath;
private import ascii = tango.text.Ascii;
private import tango.util.log.Log;
private import tango.util.MinMax;

private import lib.client;
private import lib.hashes;
private import lib.digest.stateful;
private import lib.message;

private import daemon.cache.map;
private import daemon.client;
private import daemon.lib.stateless;

version (Posix) {
    private import tango.stdc.posix.unistd;
    static if ( !is(typeof(fdatasync) == function ) )
        extern (C) int fdatasync(int);
} else {
    static assert(false, "fdatasync Needs Non-POSIX implementation");
}

const LOCALID_LENGTH = 32;
const Hashers = [HashType.TREE_TIGER];

alias void delegate(Identifier[]) HashIdsListener;

interface IStoredAsset {
    ubyte[] readChunk(ulong offset, ubyte[] buf, out ulong missing);
    void writeChunk(ulong offset, ubyte[] buf);
    bool isWritable();
    void close();
}

/*****************************************************************************************
 * Base for all kinds of cached assets. Provides basic reading functionality
 ****************************************************************************************/
class BaseAsset : private StatelessFile, public IStoredAsset {
protected:
    FilePath path;
    Logger log;
    ulong _size;
public:
    /*************************************************************************************
     * IncompleteAssetException is thrown if a not-fully-cached asset were to be Opened
     * directly as a BaseAsset
     ************************************************************************************/
    this(FilePath path) {
        this.path = path;
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
        log.trace("Closing");
        super.close();
    }

    /*************************************************************************************
     * Read a single segment from the Asset
     ************************************************************************************/
    ubyte[] readChunk(ulong offset, ubyte[] buf, out ulong missing) {
        missing = 0;
        auto got = pRead(offset, buf);
        return buf[0..got];
    }

    /*************************************************************************************
     * Adding segments is not supported for BaseAsset
     ************************************************************************************/
    void writeChunk(ulong offset, ubyte[] data) {
        throw new IOException("Trying to write to a completed file");
    }

    /*************************************************************************************
     * BaseAsset is not Writable.
     ************************************************************************************/
    bool isWritable() {
        return false;
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

    Thread hasherThread;
    Semaphore hashDataAvailable;
    bool closing = false;
public:
    /*************************************************************************************
     * Create WriteableAsset by path and size
     ************************************************************************************/
    this(FilePath path, ulong size, CacheMap cacheMap, HashIdsListener updateHashIds, bool usefsync) {
        resetHashes();
        this.cacheMap = cacheMap;
        this.updateHashIds = updateHashIds;
        this.usefsync = usefsync;
        super(path); // Parent calls open()
        if (this.length != size)
            truncate(size);           // We resize it to right size
        _size = size;
        log = Log.lookup("daemon.cache.writeasset."~path.name[0..8]); // TODO: fix order and double-init

        hasherThread = new Thread(&hasherThreadLoop);
        hasherThread.name = "Hasher:"~path.name[0..min!(uint)(6,path.name.length)];
        hashDataAvailable = new Semaphore(1);
        hasherThread.isDaemon = true;
        hasherThread.start();
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
    void assetOpen(FilePath path, File.Style style) {
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
        File.open(path.toString, style);
    }
    /// ditto
    void assetOpen(FilePath path) {
        assetOpen(path, File.Style(File.Access.ReadWrite, File.Open.Sedate));
    }

    /*************************************************************************************
     * Asynchronous read, first checking the cacheMap has the block we're looking for.
     ************************************************************************************/
    synchronized ubyte[] readChunk(ulong offset, ubyte[] buf, out ulong missing) {
        if (!buf.length) {
            missing = 0;
            return buf[0..0];
        } else if (this.cacheMap && !this.cacheMap.has(offset, buf.length)) {
            missing = buf.length; // TODO: really calculate how much is missing
            return null;
        } else {
            return super.readChunk(offset, buf, missing);
        }
    }

    /*************************************************************************************
     * Add a data-segment to the asset, and update the CacheMap
     ************************************************************************************/
    void writeChunk(ulong offset, ubyte[] data) {
        assert(!closing);
        synchronized (this) {
            if (!cacheMap)
                throw new IOException("Trying to write to a completed file");
            auto written = pWrite(offset, data);
            if (written != data.length)
                throw new IOException("Failed to write received segment. Disk full?");
            cacheMap.add(offset, written);
        }
        hashDataAvailable.notify();
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
            if (cacheMap) synchronized (cacheMap) {
                // TODO: Refactor this
                cacheMap.header.hashedAmount = hashedPtr;
                foreach (type, hasher; hashers) {
                    auto buf = new ubyte[hasher.maxStateSize];
                    cacheMap.header.hashes[type] = hasher.save(buf);
                }
            }
        }
        if (usefsync)
            fdatasync(fileHandle);
    }

    /*************************************************************************************
     * Override to also shutdown the hasherThread
     ************************************************************************************/
    synchronized void close() {
        closing = true;
        if (hasherThread) {
            log.trace("Waiting for hasherThread to close.");
            hashDataAvailable.notify();
        } else {
            super.close();
        }
    }
protected:
    /*************************************************************************************
     * Drive hashing of incoming data, to verify final digest.
     ************************************************************************************/
    void hasherThreadLoop() {
        ubyte[1024*1024] buf;
        try {
            while (hashedPtr < _size) {
                waitForData;
                ulong available;
                synchronized (this) available = cacheMap.zeroBlockSize;
                while ((available > hashedPtr) && ((!closing) || (available == _size))) {
                    auto bufsize = min(available - hashedPtr, cast(ulong)buf.length);
                    auto got = pRead(hashedPtr, buf[0..bufsize]);
                    assert(got == bufsize);
                    foreach (hash; hashers)
                        hash.update(buf[0..got]);
                    hashedPtr += got;
                    synchronized (this) available = cacheMap.zeroBlockSize;
                }
                if (closing)
                    break;
            }
            if (hashedPtr == _size) {
                finish();
            } else synchronized (this) if (closing) {
                super.close();
                hasherThread = null;
            }
        } catch (Exception e) {
            log.error("Error in hashing thread! {}", e);
        }
    }

    protected void waitForData() {
        hashDataAvailable.wait();
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
        }

        updateHashIds(hashIds);
    }
}

class RehashingAsset : WriteableAsset {
    this(FilePath path, ulong size, HashIdsListener updateHashIds) {
        auto cacheMap = new CacheMap;
        cacheMap.add(0, size);
        super(path, size, cacheMap, updateHashIds, false);
    }

    void assetOpen(FilePath path) {
        super.assetOpen(path, File.Style(File.Access.Read, File.Open.Exists));
    }

    void waitForData() {}
}