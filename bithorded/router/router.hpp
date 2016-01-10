/*
    Copyright 2012 <copyright holder> <email>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
*/


#ifndef BITHORDED_ROUTER_ROUTER_HPP
#define BITHORDED_ROUTER_ROUTER_HPP

#include <boost/asio/io_service.hpp>
#include <map>
#include <memory>
#include <unordered_set>
#include <vector>

#include "../lib/assetsessions.hpp"
#include "../lib/management.hpp"
#include "../lib/weakmap.hpp"
#include "../server/config.hpp"
#include "../server/client.hpp"
#include "asset.hpp"

#include "bithorde.pb.h"

namespace bithorded {
namespace router {

class FriendConnector;

class Router : public AssetSessions, public management::DescriptiveDirectory, public IAssetSource
{
	Server& _server;
	std::map<std::string, Config::Friend> _friends;
	std::map<std::string, std::shared_ptr<FriendConnector> > _connectors;
	std::map<std::string, Client::Ptr > _connectedFriends;

	std::unordered_set<uint64_t> _blacklist;
	std::queue< std::pair<boost::posix_time::ptime,uint64_t> > _blacklistQueue;
	bithorded::WeakSet<ForwardedAsset> _openAssets;
public:
	Router(Server& server);

	void addFriend(const Config::Friend& f);

	Server& server() { return _server; }

	std::size_t friends() const;
	std::size_t upstreams() const;

	const std::map<std::string, Client::Ptr >& connectedFriends() const;

	void onConnected(const bithorded::Client::Ptr& client);
	void onDisconnected(const bithorded::Client::Ptr& client);

	virtual UpstreamRequestBinding::Ptr findAsset(const bithorde::BindRead& req);

	virtual void inspect(management::InfoList& target) const;
    virtual void describe(management::Info& target) const;
protected:
	virtual bithorded::IAsset::Ptr openAsset(const bithorde::BindRead& req);

private:
	void _addToBlacklist(const boost::posix_time::ptime& deadline, uint64_t uid);
	bool _isBlacklisted(const boost::posix_time::ptime& now, const google::protobuf::RepeatedField< google::protobuf::uint64 >& uids);
};

}}

#endif // BITHORDED_ROUTER_ROUTER_HPP
