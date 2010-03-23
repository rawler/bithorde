/****************************************************************************************
 * Copyright: Ulrik Mikaelsson, All rights reserved
 ***************************************************************************************/
module daemon.routing.asset;

private import lib.client;
private import lib.message;

private import daemon.client;

/// Used to notify router that request completed (regardless of success)
alias void delegate(daemon.client.OpenRequest) RequestCompleted;

/****************************************************************************************
 * A ForwardedAsset represents an asset currently being forwarded from "upstream" nodes.
 * A forwarded asset SHOULD have one or more BackingAssets.
 ***************************************************************************************/
private class ForwardedAsset : IServerAsset {
    mixin IRefCounted.Impl; /// A refcounted asset
private:
    daemon.client.OpenRequest req;
    IAsset[] backingAssets;
    BHServerOpenCallback openCallback;
    RequestCompleted notify;
package:
    uint waitingResponses;
public:
    /************************************************************************************
     * Create new ForwardedAsset from a request, and save callbacks
     ***********************************************************************************/
    this (daemon.client.OpenRequest req, BHServerOpenCallback cb, RequestCompleted notify)
    {
        this.req = req;
        this.openCallback = cb;
        this.notify = notify;
    }
    ~this() {
        close();
    }

    void close() {
        assert(waitingResponses == 0); // TODO: Handle terminating stale remote requests
        foreach (asset; backingAssets)
            asset.close();
    }

    /************************************************************************************
     * Implements IServerAsset.size - size of the asset
     ***********************************************************************************/
    void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
        // TODO: Spread load on all available clients
        backingAssets[0].aSyncRead(offset, length, cb);
    }

    /************************************************************************************
     * Implements IServerAsset.size - size of the asset
     ***********************************************************************************/
    ulong size() {
        return backingAssets[0].size;
    }

package:
    /************************************************************************************
     * Callback for hooking up new-found backing assets
     ***********************************************************************************/
    void addBackingAsset(IAsset asset, Status status, lib.message.OpenOrUploadRequest req, OpenResponse resp) {
        switch (status) {
        case Status.SUCCESS:
            assert(asset, "SUCCESS response, but no asset");
            backingAssets ~= asset;
            break;
        default:
            break;
        }
        waitingResponses -= 1;
        if (waitingResponses <= 0)
            doCallback();
    }

    /************************************************************************************
     * Report back when we've got all responses
     ***********************************************************************************/
    void doCallback() {
        notify(req);
        openCallback(this, (backingAssets.length > 0) ? Status.SUCCESS : Status.NOTFOUND);
    }
}

