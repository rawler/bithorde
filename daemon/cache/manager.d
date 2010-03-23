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
private import daemon.routing.router;

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
    /************************************************************************************
     * Create a CacheManager with a given asset-directory and underlying Router-instance
     ***********************************************************************************/
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

    /************************************************************************************
     * Implements IAssetSource.findAsset. Tries to get a hold of a certain asset.
     ***********************************************************************************/
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
    /************************************************************************************
     * Implement uploading new assets to this Cache.
     ***********************************************************************************/
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
    /************************************************************************************
     * Listen to managed assets, and update appropriate indexes
     ***********************************************************************************/
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


    /*************************************************************************
     * The IdMap is a dummy-object for storing the mapping between hashIds
     * and localIds.
     ************************************************************************/
    class IdMap { // TODO: Re-work protobuf-lib so it isn't needed
        AssetMetaData[] assets;
        mixin MessageMixin!(PBField!("assets",    1)());
    }

    /*************************************************************************
     * Load id-mappings through IdMap
     ************************************************************************/
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

    /*************************************************************************
     * Save id-mappings with IdMap
     ************************************************************************/
    void saveIdMap() {
        scope auto map = new IdMap;
        map.assets = localIdMap.values;
        File.set(idMapPath.toString, map.encode());
    }

    /*************************************************************************
     * Add an asset to the id-maps
     ************************************************************************/
    void addToIdMap(AssetMetaData asset) {
        localIdMap[asset.localId] = asset;
        foreach (id; asset.hashIds) {
            hashIdMap[id.type][id.id] = asset;
        }
        saveIdMap();
    }
}