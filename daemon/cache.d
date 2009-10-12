module daemon.cache;

private import tango.core.Exception;
private import tango.core.Thread;
private import tango.io.device.File;
private import tango.io.FilePath;
private import tango.io.Stdout;

private import daemon.client;
private import lib.asset;
private import message = lib.message;
private import lib.client;
private import tango.core.Thread;
alias message.HashType HashType;

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
    HashType _hType;
    ubyte[] _id;
public:
    this(CacheManager mgr, HashType hType, ubyte[] id) {
        this.mgr = mgr;
        this._hType = hType;
        this._id = id.dup;
        super(FilePath.join(mgr.assetDir, bytesToHex(id)), File.ReadWriteExisting);
        this.mgr.assets[this.id] = this;
    }
    ~this() {
        mgr.assets.remove(id);
    }

    void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
        ubyte[] buf = tlsBuffer(length);
        seek(offset);
        auto got = super.read(buf);
        cb(this, offset, buf[0..got], message.Status.SUCCESS);
    }

    final ulong size() {
        return super.length;
    }

    final HashType hashType() { return _hType; }
    final AssetId id() { return _id; }

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
    CachedAsset getAsset(HashType hType, ubyte[] id) {
        if (auto asset = id in assets) {
            assert(asset.hashType == hType);
            asset.takeRef();
            return *asset;
        } else {
            try {
                auto newAsset = new CachedAsset(this, hType, id);
                newAsset.takeRef();
                return newAsset;
            } catch (IOException e) {
                return null;
            }
        }
    }
}