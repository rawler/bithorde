module daemon.cache;

private import tango.io.device.File;
private import tango.io.FilePath;
private import tango.io.Stdout;

private import lib.asset;
private import lib.message;
private import lib.client;
alias BitHordeMessage.HashType HashType;

class CachedAsset : public File, IAsset {
protected:
    CacheManager mgr;
    HashType hType;
    ubyte[] id;
public:
    this(CacheManager mgr, HashType hType, ubyte[] id) {
        super(FilePath.join(mgr.assetDir, bytesToHex(id)), File.ReadWriteExisting);
        this.hType = hType;
        this.id = id.dup;
    }

    void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
        ubyte[] buf = new ubyte[length];
        seek(offset);
        auto got = super.read(buf);
        assert(got == length);
        cb(this, offset, buf, BHStatusCode.SUCCESS);
    }

    ulong size() {
        return super.length;
    }
}

class CacheManager {
protected:
    char[] assetDir;
    CachedAsset[ubyte[]] assets;
public:
    this(char[] assetDir) {
        this.assetDir = assetDir;
    }
    IAsset getAsset(HashType hType, ubyte[] id) {
        if (auto asset = id in assets) {
            assert(asset.hType == hType);
            return *asset;
        } else {
            auto newAsset = new CachedAsset(this, hType, id);
            assets[id] = newAsset;
            return newAsset;
        }
    }
}