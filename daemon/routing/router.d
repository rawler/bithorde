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
module daemon.routing.router;

private import tango.time.Time;
private import tango.util.Convert;
private import tango.util.log.Log;

private import lib.httpserver;
private import lib.message;

private import daemon.routing.friend;
private import daemon.routing.asset;
private import daemon.client;
private import daemon.server;

/****************************************************************************************
 * The router is responsible for dispatching requests to directly connected friend-nodes,
 * and keep track of currently forwarded requests.
 ***************************************************************************************/
class Router : IAssetSource {
private:
    ForwardedAsset[ulong] openRequests;
    Friend[Client] connectedFriends;
    Logger log;
public:
    this() {
        log = Log.lookup("daemon.router.manager");
    }

    /************************************************************************************
     * Implements IAssetSource.find. Unless request is already under forwarding, forward
     * to all connected friends.
     ***********************************************************************************/
    bool findAsset(daemon.client.BindRead req) {
        if (req.uuid in openRequests)
            req.callback(null, Status.WOULD_LOOP, null);
        else
            forwardBindRead(req);
        return true;
    }

    /************************************************************************************
     * Assign already connected friend to this router
     ***********************************************************************************/
    void registerFriend(Friend f) {
        connectedFriends[f.c] = f;
    }

    /************************************************************************************
     * Disconnect friend from this router
     ***********************************************************************************/
    Friend unregisterFriend(Client c) {
        if (c in connectedFriends) {
            auto friend = connectedFriends[c];
            connectedFriends.remove(c);
            return friend;
        } else {
            return null;
        }
    }

    /************************************************************************************
     * Handles incoming management-requests
     ***********************************************************************************/
    MgmtEntry[] onManagementRequest(char[][] path) {
        if (path.length) {
            throw new HTTPMgmtProxy.Error(404, "Unknown path");
        } else {
            MgmtEntry[] res;
            foreach (f; connectedFriends) {
                auto connect_parms = (f.c && f.c.peerAddress) ? f.c.peerAddress.toString : "unknown";
                res ~= MgmtEntry(f.name, connect_parms);
            }
            return res;
        }
    }

    /************************************************************************************
     * Expose number of connected friends.
     ***********************************************************************************/
    uint friendCount() {
        return connectedFriends.length;
    }
private:
    /************************************************************************************
     * Remove request from list of in-flight-openRequests
     ***********************************************************************************/
    void openRequestCompleted(daemon.client.BindRead req) {
        this.openRequests.remove(req.uuid);
    }

    /************************************************************************************
     * Work-horse of forwarding, iterate through connected friends and send out forwarded
     * requests.
     ***********************************************************************************/
    // TODO: Exception-handling; what if sending to friend fails?
    void forwardBindRead(daemon.client.BindRead req) {
        log.trace("Forwarding request among {} friends", connectedFriends.length);
        auto asset = new ForwardedAsset(req, &openRequestCompleted);
        foreach (friend; connectedFriends) {
            auto client = friend.c;
            if (client != req.client) {
                auto timeout = TimeSpan.fromMillis(req.timeout-200);
                log.trace("Forwarding to {} with timeout {}ms", friend.name, timeout.millis);
                asset.waitingResponses += 1;
                // TODO: Randomize timeouts
                client.open(req.ids, &asset.addBackingAsset, req.uuid, timeout);
            }
        }
        if (!asset.waitingResponses)
            asset.doCallback();
        else
            openRequests[req.uuid] = asset;
    }
}