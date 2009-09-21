module daemon.cache;

private import tango.io.device.File;
private import tango.io.FilePath;
private import tango.io.Stdout;

private import daemon.client;
private import lib.asset;
private import lib.message;
private import lib.client;
alias BitHordeMessage.HashType HashType;

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
        super(FilePath.join(mgr.assetDir, bytesToHex(id)), File.ReadWriteExisting);
    }
    ~this() {
        mgr.assets.remove(id);
    }

    void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
        ubyte[] buf = new ubyte[length];
        seek(offset);
        auto got = super.read(buf);
        assert(got == length);
        cb(this, offset, buf, BHStatus.SUCCESS);
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
            assets[id] = newAsset;
            return newAsset;
        }
    }
}