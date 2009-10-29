module daemon.cache;

private import tango.core.Exception;
private import tango.core.Thread;
private import tango.io.device.File;
private import tango.io.device.FileMap;
private import tango.io.FilePath;
private import tango.io.Stdout;
private import tango.math.random.Random;

private import daemon.client;
private import daemon.hashes;
private import lib.asset;
private import message = lib.message;
private import lib.client;
private import tango.core.Thread;
alias message.HashType HashType;

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

class MissingSegmentException : Exception {
    this(char[] msg) { super(msg); }
}

// Note: Doesn't deal with 0-length files
private final class CacheMap {
private:
    struct Segment {
        ulong start;
        ulong end;

        bool isEmpty() { return !end; }
        void opOrAssign(Segment other) {
            if (other.start < this.start)
                this.start = other.start;
            if (this.end < other.end)
                this.end = other.end;
        }
        Segment grow(uint amount=1) {
            return Segment(start?start-amount:start, end+amount);
        }
    }
    Segment[] segments;
    uint segcount;
    MappedFile file;
    FilePath path;
    void ensureIdxAvail(uint length) {
        if (length > segments.length)
            segments = cast(Segment[])file.resize(Segment.sizeof * length);
    }
public:
    this(FilePath path) {
        this.path = path;
        file = new MappedFile(path.toString, File.ReadWriteCreate);
        if (file.length)
            segments = cast(Segment[])file.map();
        else
            segments = cast(Segment[])file.resize(Segment.sizeof * 16);
        for (; !segments[segcount].isEmpty; segcount++) {}
    }

    ~this() {
        if (file)
            file.close();
    }

    /**
     * Check if a segment is covered by the cache.
     */
    bool has(ulong start, uint length) {
        auto end = start+length;
        uint i;
        for (; (i < segcount) && (segments[i].end < start); i++) {}
        if (i==segcount)
            return false;
        else
            return (start>=segments[i].start) && (end<=segments[i].end);
    }

    /**
     * Add a segment to the cachemap
     */
    void add(ulong start, uint length) {
        // Original new segment
        auto onew = Segment(start, start + length);

        // Expand start and end with 1, to cover adjacency
        auto anew = onew.grow(1);

        uint i;
        // Find insertion-point
        for (; (i < segcount) && (segments[i].end <= anew.start); i++) {}
        assert(i <= segcount);

        // Append, Update or Insert ?
        if (i == segcount) {
            // Append
            if ((++segcount) > segments.length)
                ensureIdxAvail(segments.length*2);
            segments[i] = onew;
        } else if (segments[i].start <= anew.end) {
            // Update
            segments[i] |= onew;
        } else {
            // Insert, need to ensure we have space, and shift trailing segments up a position
            if (++segcount > segments.length)
                ensureIdxAvail(segments.length*2);
            for (auto j=segcount;j>i;j--)
                segments[j] = segments[j-1];
            segments[i] = onew;
        }

        // Squash possible trails (merge any intersecting or adjacent segments)
        uint j = i+1;
        for (;(j < segcount) && (segments[j].start <= (segments[i].end+1)); j++)
            segments[i] |= segments[j];

        // Right-shift the rest
        uint shift = j-i-1;
        if (shift) {
            segcount -= shift; // New segcount
            // Shift down valid segments
            for (i+=1; i < segcount; i++)
                segments[i] = segments[i+shift];
            // Zero-fill superfluous segments
            for (;shift; shift--)
                segments[i++] = Segment.init;
        }
    }

    void flush() {
        file.flush();
    }

    /**
     * Returns the size of any block starting at offset 0, or 0, if no such block exists
     */
    ulong zeroBlockSize() {
        if (segments[0].start == 0)
            return segments[0].end;
        else
            return 0;
    }

    unittest {
        auto path = new FilePath("/tmp/bh-unittest-testmap");
        void cleanup() {
            if (path.exists)
                path.remove();
        }
        cleanup();
        scope(exit) cleanup();

        auto map = new CacheMap(path.toString);
        map.add(0,15);
        assert(map.segments[0].start == 0);
        assert(map.segments[0].end == 15);
        map.add(30,15);
        assert(map.segments[1].start == 30);
        assert(map.segments[1].end == 45);
        assert(map.segments[2].start == 0);
        assert(map.segments[2].end == 0);
        map.add(45,5);
        assert(map.segments[1].start == 30);
        assert(map.segments[1].end == 50);
        assert(map.segments[2].start == 0);
        assert(map.segments[2].end == 0);
        map.add(25,5);
        assert(map.segments[1].start == 25);
        assert(map.segments[1].end == 50);
        assert(map.segments[2].start == 0);
        assert(map.segments[2].end == 0);

        map.add(18,2);
        assert(map.segments[0].start == 0);
        assert(map.segments[0].end == 15);
        assert(map.segments[1].start == 18);
        assert(map.segments[1].end == 20);
        assert(map.segments[2].start == 25);
        assert(map.segments[2].end == 50);

        map.add(11,7);
        assert(map.segments[0].start == 0);
        assert(map.segments[0].end == 20);
        assert(map.segments[1].start == 25);
        assert(map.segments[1].end == 50);
        assert(map.segments[2].start == 0);
        assert(map.segments[2].end == 0);

        assert(map.has(0,10) == true);
        assert(map.has(1,15) == true);
        assert(map.has(16,15) == false);
        assert(map.has(29,5) == true);
        assert(map.has(30,5) == true);
        assert(map.has(35,5) == true);
        assert(map.has(45,5) == true);
        assert(map.has(46,5) == false);
    }
}

class CachedAsset : public File, IServerAsset {
protected:
    CacheManager mgr;
    ubyte[] _id;
    CacheMap cacheMap;
public:
    this(CacheManager mgr, ubyte[] id) {
        this.mgr = mgr;
        this._id = id.dup;
        super(mgr.uploadPath.dup.append(bytesToHex(id)).toString, File.ReadWriteCreate);
        this.mgr.assets[this.id] = this;
    }
    ~this() {
        if (cacheMap)
            delete cacheMap;
        mgr.assets.remove(id);
    }

    synchronized void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
        if (cacheMap && !cacheMap.has(offset, length))
            throw new MissingSegmentException("Missing given segment");
        ubyte[] buf = tlsBuffer(length);
        seek(offset);
        auto got = super.read(buf);
        cb(this, offset, buf[0..got], message.Status.SUCCESS);
    }

    synchronized void add(ulong offset, ubyte[] data) {
        if (!cacheMap)
            throw new IOException("Trying to write to a completed file");
        seek(offset);
        write(data);
        cacheMap.add(offset, data.length);
    }

    final ulong size() {
        return super.length;
    }

    final HashType hashType() { return HashType.init; } // TODO: Change API to support multi-hash
    final AssetId id() { return _id; }

    mixin IRefCounted.Impl;
}

class UploadAsset : public CachedAsset {
private:
    Hash[char[]] hashes;
    uint hashingptr;
public:
    this(CacheManager mgr, ulong size)
    in { assert(size > 0); }
    body{
        scope auto tempId = new ubyte[32];
        rand.randomizeUniform!(ubyte[],false)(tempId);
        super(mgr, tempId);
        cacheMap = new CacheMap(mgr.uploadPath.dup.append(bytesToHex(tempId)).suffix("idx"));
        truncate(size);
        foreach (k,factory; HashMap)
            hashes[k] = factory();
    }
    synchronized void add(ulong offset, ubyte[] data) {
        super.add(offset, data);
        auto zeroBlockSize = cacheMap.zeroBlockSize;
        if (zeroBlockSize > hashingptr) {
            scope auto newdata = new ubyte[zeroBlockSize - hashingptr];
            seek(hashingptr);
            auto read = read(newdata);
            assert(read == newdata.length);
            foreach (hash; hashes) {
                hash.update(newdata);
            }
            if (zeroBlockSize == length)
                finish();
            else
                hashingptr = zeroBlockSize;
        }
    }
private:
    void finish() {
        assert(cacheMap.segcount == 1);
        assert(cacheMap.segments[0].start == 0);
        assert(cacheMap.segments[0].end == length);
        foreach (hash; hashes) {
            Stderr.format("Hash {}: {}", hash.name, hash.hexDigest).newline;
        }
        cacheMap.path.remove();
        delete cacheMap;
    }
}

class CacheManager {
protected:
    char[] assetDir;
    CachedAsset[ubyte[]] assets;
    FilePath uploadPath;
public:
    this(char[] assetDir) {
        this.assetDir = assetDir;
        uploadPath = new FilePath(FilePath.join(assetDir, "upload"));
        if (!uploadPath.exists)
            uploadPath.createFolder();
        foreach (k,v; HashMap) {
            scope auto fp = new FilePath(FilePath.join(assetDir, k));
            if (!fp.exists)
                fp.createFolder();
        }
    }
    CachedAsset getAsset(HashType hType, ubyte[] id) {
        if (auto asset = id in assets) {
            assert(asset.hashType == hType);
            asset.takeRef();
            return *asset;
        } else {
            try {
                auto newAsset = new CachedAsset(this, id);
                newAsset.takeRef();
                return newAsset;
            } catch (IOException e) {
                Stderr("While opening asset", e).newline;
                return null;
            }
        }
    }
    UploadAsset uploadAsset(UploadRequest req) {
        try {
            auto newAsset = new UploadAsset(this, req.size);
            newAsset.takeRef();
            return newAsset;
        } catch (IOException e) {
            Stderr("While opening asset", e).newline;
            return null;
        }
    }
}