/****************************************************************************************
 * Copyright: Ulrik Mikaelsson, All rights reserved
 ***************************************************************************************/

module daemon.cache.manager;

private import tango.core.Exception;
private import tango.io.device.File;
private import tango.io.FilePath;
private import tango.util.log.Log;

private import lib.protobuf;

import daemon.cache.asset;
private import daemon.cache.metadata;
private import daemon.client;
private import daemon.config;
private import daemon.router;

private class IdMap {
    AssetMetaData[] assets;
    mixin MessageMixin!(PBField!("assets",    1)());
}

/****************************************************************************************
 * Overseeing Cache-manager, keeping state of all cache-assets, and mapping from id:s to
 * Assets.
 *
 * Copyright: Ulrik Mikaelsson, All rights reserved
 ***************************************************************************************/
class CacheManager : IAssetSource {
protected:
    AssetMetaData hashIdMap[message.HashType][ubyte[]];
    FilePath idMapPath;
    FilePath assetDir;
    Router router;
    AssetMetaData localIdMap[ubyte[]];
    CachedAsset[ubyte[]] openAssets;

    static Logger log;
    static this() {
        log = Log.lookup("daemon.cache.manager");
    }
public:

    this(FilePath assetDir, Router router) {
        if (!(assetDir.exists && assetDir.isFolder && assetDir.isWritable))
            throw new ConfigException(assetDir.toString ~ " must be an existing writable directory");
        this.assetDir = assetDir;
        this.router = router;

        idMapPath = this.assetDir.dup.append("index.protobuf");
        if (idMapPath.exists)
            loadIdMap();
        else {
            hashIdMap[message.HashType.SHA1] = null;
            hashIdMap[message.HashType.SHA256] = null;
            hashIdMap[message.HashType.TREE_TIGER] = null;
            hashIdMap[message.HashType.ED2K] = null;
        }
    }
    IServerAsset findAsset(OpenRequest req, BHServerOpenCallback cb) {
        IServerAsset fromCache(CachedAsset asset) {
            asset.takeRef();
            log.trace("serving {} from cache", hex.encode(asset.id));
            req.callback(asset, message.Status.SUCCESS);
            return asset;
        }
        IServerAsset openAsset(ubyte[] localId) {
            try {
                auto newAsset = new CachedAsset(assetDir, localId, &_assetLifeCycleListener);
                newAsset.open();
                return fromCache(newAsset);
            } catch (IOException e) {
                log.error("While opening asset: {}", e);
                return null;
            }
        }
        IServerAsset forwardRequest() {
            auto asset = new CachingAsset(assetDir, cb, req.ids, &_assetLifeCycleListener);
            asset.takeRef();
            return router.findAsset(req, &asset.remoteCallback);
        }

        ubyte[] localId;
        foreach (id; req.ids) {
            if (id.id in hashIdMap[id.type]) {
                auto assetMeta = hashIdMap[id.type][id.id];
                localId = assetMeta.localId;
                break;
            }
        }
        if (!localId) {
            log.trace("Unknown asset, forwarding {}", req);
            return forwardRequest();
        } else if (localId in openAssets) {
            return fromCache(openAssets[localId]);
        } else {
            return openAsset(localId);
        }
    }
    WriteableAsset uploadAsset(UploadRequest req) {
        try {
            auto newAsset = new WriteableAsset(assetDir, &_assetLifeCycleListener);
            newAsset.create(req.size);
            newAsset.takeRef();
            return newAsset;
        } catch (IOException e) {
            log.error("While opening upload asset: {}", e);
            return null;
        }
    }

private:
    void _assetLifeCycleListener(CachedAsset asset, AssetState state) {
        switch (state) {
        case AssetState.ALIVE:
            openAssets[asset.id] = asset;
            break;
        case AssetState.GOTIDS:
            addToIdMap(asset.metadata);
            break;
        case AssetState.DEAD:
            openAssets.remove(asset.id);
            break;
        }
    }

    void loadIdMap() {
        scope auto mapsrc = new IdMap();
        scope auto fileContent = cast(ubyte[])File.get(idMapPath.toString);
        mapsrc.decode(fileContent);
        foreach (asset; mapsrc.assets) {
            localIdMap[asset.localId] = asset;
            foreach (id; asset.hashIds)
                hashIdMap[id.type][id.id] = asset;
        }
    }

    void saveIdMap() {
        scope auto map = new IdMap;
        map.assets = localIdMap.values;
        File.set(idMapPath.toString, map.encode());
    }

    void addToIdMap(AssetMetaData asset) {
        localIdMap[asset.localId] = asset;
        foreach (id; asset.hashIds) {
            hashIdMap[id.type][id.id] = asset;
        }
        saveIdMap();
    }
}