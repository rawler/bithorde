/****************************************************************************************
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
module daemon.routing.asset;

private import tango.util.log.Log;

private import lib.client;
private import lib.message;

private import daemon.client;

/// Used to notify router that request completed (regardless of success)
alias void delegate(daemon.client.BindRead) RequestCompleted;

/****************************************************************************************
 * A ForwardedAsset represents an asset currently being forwarded from "upstream" nodes.
 * A forwarded asset SHOULD have one or more BackingAssets.
 ***************************************************************************************/
private class ForwardedAsset : IServerAsset {
    mixin IAsset.StatusSignal;
private:
    daemon.client.BindRead req;
    IAsset[] backingAssets;
    RequestCompleted notify;
    uint reqnum;
    Logger log;
package:
    uint waitingResponses;
public:
    /************************************************************************************
     * Create new ForwardedAsset from a request, and save callbacks
     ***********************************************************************************/
    this (daemon.client.BindRead req, RequestCompleted notify)
    {
        this.req = req;
        this.notify = notify;
        this.log = Log.lookup("router.asset");
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
     * Implement IServerAsset.hashIds
     ***********************************************************************************/
    Identifier[] hashIds() {
        // TODO: AssetStatus should also include hashIds, which should be preffered
        return req.ids;
    }

    /************************************************************************************
     * Implements IServerAsset.size - size of the asset
     ***********************************************************************************/
    void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
        auto forwardIdx = (reqnum++) % backingAssets.length; // Round-robin over available backingAssets
        backingAssets[forwardIdx].aSyncRead(offset, length, cb);
    }

    /************************************************************************************
     * Implements IServerAsset.size - size of the asset
     ***********************************************************************************/
    ulong size() {
        return backingAssets[0].size;
    }

private:
    void onUpdatedStatus(IAsset asset, Status status, AssetStatus resp) {
        log.trace("Got updated backingAsset status {}", statusToString(status));
        if (status != Status.SUCCESS) {
            // Remove backingAsset
            auto newBackingAssets = new IAsset[0];
            foreach (a; backingAssets) {
                if (a != asset)
                    newBackingAssets ~= a;
            }
            auto oldBackingAssets = backingAssets;
            backingAssets = newBackingAssets;
            delete oldBackingAssets;

            scope fwd = new AssetStatus;
            fwd.status = (backingAssets.length > 0) ? Status.SUCCESS : Status.NOTFOUND;
            fwd.availability = backingAssets.length*5;
            statusSignal.call(this, fwd.status, fwd);
        }
    }

package:
    /************************************************************************************
     * Callback for hooking up new-found backing assets
     ***********************************************************************************/
    void addBackingAsset(IAsset asset, Status status, AssetStatus resp) {
        switch (status) {
        case Status.SUCCESS:
            assert(asset, "SUCCESS response, but no asset");
            assert(asset.size > 0, "Empty asset");
            asset.statusSignal.attach(&onUpdatedStatus);
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
        scope s = new message.AssetStatus;
        s.status = (backingAssets.length > 0) ? Status.SUCCESS : Status.NOTFOUND;
        s.availability = backingAssets.length*5;
        req.callback(this, s.status, s);
    }
}

