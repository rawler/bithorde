module daemon.router;

private import daemon.client;
private import daemon.friend;
private import daemon.server;
private import lib.asset;
private import lib.message;

private class ForwardedAsset : IServerAsset {
private:
    Router router;
    ubyte[] _id;
    HashType _hType;
    IAsset[] backingAssets;
    BHServerOpenCallback openCallback;
package:
    ulong[] requests;
    uint waitingResponses;
public:
    this (Router router, HashType hType, ubyte[] id, BHServerOpenCallback cb)
    {
        this.router = router;
        this._hType = hType;
        this._id = id;
        this.openCallback = cb;
        this.waitingResponses = 0;
    }
    ~this() {
        assert(waitingResponses == 0); // We've got to fix timeouts some day.
        foreach (asset; backingAssets)
            delete asset;
    }

    final HashType hashType() { return _hType; }
    final AssetId id() { return _id; }

    void addRequest(ulong reqid) {
        requests ~= reqid;
    }
    void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
        backingAssets[0].aSyncRead(offset, length, cb);
    }
    ulong size() {
        return backingAssets[0].size;
    }
    void addBackingAsset(IAsset asset, Status status) {
        switch (status) {
        case Status.SUCCESS:
            backingAssets ~= asset;
            break;
        case Status.NOTFOUND:
            break;
        case Status.WOULD_LOOP:
            break;
        }
        waitingResponses -= 1;
        if (waitingResponses <= 0)
            doCallback();
    }
    mixin IRefCounted.Impl;
package:
    void doCallback() {
        router.openRequests.remove(id);
        openCallback(this, (backingAssets.length > 0) ? Status.SUCCESS : Status.NOTFOUND);
    }
}

class Router : IAssetSource {
private:
    Server server;
    ForwardedAsset[ubyte[]] openRequests;
    Friend[Client] connectedFriends;
public:
    this(Server server) {
        this.server = server;
    }

    ForwardedAsset getAsset(HashType hType, ubyte[] id, ulong reqid, BHServerOpenCallback callback, Client origin) {
        ForwardedAsset asset;
        if (id in openRequests) {
            asset = openRequests[id];
            assert(reqid == asset.requests[0]); // TODO: Handle merging independent requests
            callback(null, Status.WOULD_LOOP);
        } else {
            asset = forwardOpenRequest(hType, id, reqid, callback, origin);
        }
        return asset;
    }

    void registerFriend(Friend f) {
        connectedFriends[f.c] = f;
    }

    Friend unregisterFriend(Client c) {
        if (c in connectedFriends) {
            auto friend = connectedFriends[c];
            connectedFriends.remove(c);
            return friend;
        } else {
            return null;
        }
    }
private:
    ForwardedAsset forwardOpenRequest(HashType hType, ubyte[] id, ulong reqid, BHServerOpenCallback callback, Client origin) {
        bool forwarded = false;
        auto asset = new ForwardedAsset(this, hType, id, callback);
        asset.addRequest(reqid);
        asset.takeRef();
        foreach (friend; connectedFriends) {
            auto client = friend.c;
            if (client != origin) {
                asset.waitingResponses += 1;
                client.open(hType, id, &asset.addBackingAsset, reqid);
                forwarded = true;
            }
        }
        if (!forwarded) {
            asset.doCallback();
            delete asset;
            return null;
        } else {
            openRequests[id] = asset;
            return asset;
        }
    }
}