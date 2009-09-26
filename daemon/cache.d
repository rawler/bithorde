module daemon.cache;

private import tango.core.Thread;
private import tango.io.device.File;
private import tango.io.FilePath;
private import tango.io.Stdout;

private import daemon.client;
private import lib.asset;
private import lib.message;
private import lib.client;
private import tango.core.Thread;
alias BitHordeMessage.HashType HashType;

static ThreadLocal!(ubyte[]) tls_buf;
static this() {
    tls_buf = new ThreadLocal!(ubyte[]);
}

static ubyte[] tlsBuffer(uint size) {
    auto buf = tls_buf.val;
    if (buf == (ubyte[]).init) {
        buf = new ubyte[size];
        tls_buf.val = buf;
    } else if (size > buf.length) {
        buf.length = size;
    }
    return buf;
}

class CachedAsset : public File, IServerAsset {
protected:
    CacheManager mgr;
    HashType hType;
    ubyte[] id;
public:
    this(CacheManager mgr, HashType hType, ubyte[] id) {
        this.mgr = mgr;
        this.hType = hType;
        this.id = id.dup;
        this.mgr.assets[this.id] = this;
        super(FilePath.join(mgr.assetDir, bytesToHex(id)), File.ReadWriteExisting);
    }
    ~this() {
        mgr.assets.remove(id);
    }

    void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
        ubyte[] buf = tlsBuffer(length);
        seek(offset);
        auto got = super.read(buf);
        assert(got == length);
        cb(this, offset, buf[0..got], BHStatus.SUCCESS);
    }

    ulong size() {
        return super.length;
    }

    mixin IRefCounted.Impl;
}

class CacheManager {
protected:
    char[] assetDir;
    CachedAsset[ubyte[]] assets;
public:
    this(char[] assetDir) {
        this.assetDir = assetDir;
    }
    IServerAsset getAsset(HashType hType, ubyte[] id) {
        if (auto asset = id in assets) {
            assert(asset.hType == hType);
            asset.takeRef();
            return *asset;
        } else {
            auto newAsset = new CachedAsset(this, hType, id);
            newAsset.takeRef();
            return newAsset;
        }
    }
}