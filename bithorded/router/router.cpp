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

#include "router.hpp"

#include <boost/asio/deadline_timer.hpp>
#include <boost/asio/placeholders.hpp>
#include <boost/date_time/posix_time/posix_time.hpp>
#include <boost/lexical_cast.hpp>
#include <boost/make_shared.hpp>

#include <glog/logging.h>

#include "../server/server.hpp"

namespace asio = boost::asio;
using namespace bithorded;
using namespace bithorded::router;
using namespace std;

const boost::posix_time::seconds RECONNECT_INTERVAL(5);

class bithorded::router::FriendConnector : public boost::enable_shared_from_this<bithorded::router::FriendConnector> {
	Server& _server;
	boost::shared_ptr<boost::asio::ip::tcp::socket> _socket;
	boost::asio::ip::tcp::resolver _resolver;
	boost::asio::deadline_timer _timer;
	boost::asio::ip::tcp::resolver::query _q;
	bool _cancelled;
public:
	FriendConnector(Server& server, const bithorded::Friend& cfg) :
		_server(server),
		_socket(boost::make_shared<boost::asio::ip::tcp::socket>(server.ioService())),
		_resolver(server.ioService()),
		_timer(server.ioService()),
		_q(cfg.addr, boost::lexical_cast<string>(cfg.port)),
		_cancelled(false)
	{
	}

	static boost::shared_ptr<FriendConnector> create(Server& server, const bithorded::Friend& cfg) {
		auto res = boost::make_shared<FriendConnector>(server, cfg);
		res->start();
		return res;
	}

	void cancel() {
		_cancelled = true;
	}

private:
	void scheduleRestart(boost::posix_time::time_duration delay=RECONNECT_INTERVAL) {
		_timer.expires_from_now(delay);
		_timer.async_wait(boost::bind(&FriendConnector::start, shared_from_this()));
	}

	void start() {
		if (!_cancelled)
			_resolver.async_resolve(_q, boost::bind(&FriendConnector::hostResolved, shared_from_this(), asio::placeholders::error, asio::placeholders::iterator));
	}

	void hostResolved(const boost::system::error_code& error, boost::asio::ip::tcp::resolver::iterator iterator)
	{
		if (error) {
			scheduleRestart();
		} else if (!_cancelled) {
			_socket->async_connect(iterator->endpoint(), boost::bind(&FriendConnector::connectionDone, shared_from_this(), asio::placeholders::error));
		}
	}

	void connectionDone(const boost::system::error_code& error) {
		if (error) {
			scheduleRestart();
		} else if (!_cancelled) {
			_server.onTCPConnected(_socket);
			scheduleRestart(RECONNECT_INTERVAL * 2);
		}
	}
};

bithorded::router::Router::Router(Server& server)
	: _server(server)
{
}

void bithorded::router::Router::addFriend(const bithorded::Friend& f)
{
	_connectors[f.name] = FriendConnector::create(_server, f);
	_friends[f.name] = f;
}

void Router::onConnected(const bithorded::Client::Ptr& client )
{
	string peerName = client->peerName();
	if (_friends.count(peerName)) {
		LOG(INFO) << "Friend " << peerName << " connected" << endl;
		if (_connectors[peerName].get())
			_connectors[peerName]->cancel();
		_connectors.erase(peerName);
		_connectedFriends[peerName] = client;
	}
}

void Router::onDisconnected(const bithorded::Client::Ptr& client)
{
	string peerName = client->peerName();
	if (_connectedFriends.erase(peerName))
		_connectors[peerName] = FriendConnector::create(_server, _friends[peerName]);
}

bithorded::Asset::Ptr bithorded::router::Router::findAsset(const bithorde::BindRead& req)
{
	if (_sessionMap.count(req.uuid()))
		throw BindError(bithorde::WOULD_LOOP);
	auto asset = boost::make_shared<ForwardedAsset, Router&, const BitHordeIds&>(*this, req.ids());
	_sessionMap[req.uuid()] = asset;

	asset->bindUpstreams(_connectedFriends, req.uuid());
	return asset;
}





