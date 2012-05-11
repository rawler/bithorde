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
#include <boost/function.hpp>
#include <boost/shared_ptr.hpp>
#include <vector>

#include "../server/config.hpp"
#include "../server/client.hpp"

#include "bithorde.pb.h"

namespace bithorded {
namespace router {

class FriendConnector;

class Router
{
	Server& _server;
	std::map<std::string, Friend> _friends;
	std::map<std::string, boost::shared_ptr<FriendConnector> > _connectors;
	std::map<std::string, Client::Ptr > _connectedFriends;
public:
	Router(Server& server);

	void addFriend(const Friend& f);

	Server& server() { return _server; }

	void onConnected(const bithorded::Client::Ptr& client);
	void onDisconnected(const bithorded::Client::Ptr& client);
	void findAsset(::bithorde::BindRead req, Asset::Target tgt);

};

}}

#endif // BITHORDED_ROUTER_ROUTER_HPP
