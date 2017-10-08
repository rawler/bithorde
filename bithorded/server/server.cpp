/*
    Copyright 2016 Ulrik Mikaelsson <ulrik.mikaelsson@gmail.com>

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

#include "server.hpp"
#include "listen.hpp"

#include <boost/filesystem.hpp>
#include <iostream>
#include <system_error>

#include <bithorded/lib/log.hpp>
#include <bithorded/server/client.hpp>
#include <bithorded/server/config.hpp>

#include "buildconf.hpp"

using namespace std;

namespace asio = boost::asio;
namespace fs = boost::filesystem;

using namespace bithorded;

namespace bithorded {
	Logger serverLog;
}

BindError::BindError(bithorde::Status status):
	runtime_error("findAsset failed with " + bithorde::Status_Name(status)),
	status(status)
{
}

void ConnectionList::inspect(management::InfoList& target) const
{
	for (auto iter=begin(); iter != end(); iter++) {
		if (auto conn = iter->second.lock()) {
			target.append(iter->first, *conn);
		}
	}
}

void ConnectionList::describe(management::Info& target) const
{
	target << size() << " connections";
}

bithorded::Config::Client null_client;

Server::Server(asio::io_service& ioSvc, Config& cfg) :
	GrandCentralDispatch(ioSvc, cfg.parallel),
	_cfg(cfg),
	_timerSvc(new TimerService(ioSvc)),
	_tcpListener(ioSvc),
	_localListener(ioSvc),
	_router(*this),
	_cache(*this, _router, cfg.cacheDir, static_cast<intmax_t>(cfg.cacheSizeMB)*1024*1024)
{
	for (auto iter=_cfg.sources.begin(); iter != _cfg.sources.end(); iter++)
		_assetStores.push_back( unique_ptr<source::Store>(new source::Store(*this, iter->name, iter->root)) );

	for (auto iter=_cfg.friends.begin(); iter != _cfg.friends.end(); iter++)
		_router.addFriend(*iter);

	if (auto fd = sd_get_named_socket("tcp")) {
		_tcpListener.assign(asio::ip::tcp::v4(), fd);
		BOOST_LOG_SEV(serverLog, info) << "TCP socket given from environment " << _tcpListener.local_endpoint().port();
	} else if (_cfg.tcpPort) {
		auto tcpPort = asio::ip::tcp::endpoint(asio::ip::tcp::v4(), _cfg.tcpPort);
		_tcpListener.open(tcpPort.protocol());
		_tcpListener.set_option(asio::ip::tcp::acceptor::reuse_address(true));
		_tcpListener.bind(tcpPort);
		_tcpListener.listen();
		BOOST_LOG_SEV(serverLog, info) << "Listening on tcp port " << _cfg.tcpPort;
	}
	waitForTCPConnection();

	if (auto fd = sd_get_named_socket("unix")) {
		_localListener.assign(asio::local::stream_protocol(), fd);
		BOOST_LOG_SEV(serverLog, info) << "Local socket given from environment " << _localListener.local_endpoint().path();
	} else if (!_cfg.unixSocket.empty()) {
		if (fs::exists(_cfg.unixSocket))
			fs::remove(_cfg.unixSocket);
		mode_t permissions = strtol(_cfg.unixPerms.c_str(), NULL, 0);
		if (!permissions)
			throw std::runtime_error("Failed to parse permissions for UNIX-socket");
		auto localPort = asio::local::stream_protocol::endpoint(_cfg.unixSocket);
		_localListener.open(localPort.protocol());
		_localListener.set_option(asio::local::stream_protocol::acceptor::reuse_address(true));
		_localListener.bind(localPort);
		_localListener.listen(4);
		if (chmod(localPort.path().c_str(), permissions) == -1)
			throw std::system_error(errno, std::system_category());
		BOOST_LOG_SEV(serverLog, info) << "Listening on local socket " << localPort;
	}
	waitForLocalConnection();

	if (_cfg.inspectPort) {
		_httpInterface.reset(new http::server::server(this->ioSvc(), "127.0.0.1", _cfg.inspectPort, *this));
		BOOST_LOG_SEV(serverLog, info) << "Inspection interface listening on port " << _cfg.inspectPort;
	}

	BOOST_LOG_SEV(serverLog, info) << "Server started, version " << bithorde::build_version;
}

void Server::waitForTCPConnection()
{
	std::shared_ptr<asio::ip::tcp::socket> sock = std::make_shared<asio::ip::tcp::socket>(ioSvc());
	_tcpListener.async_accept(*sock, [=](const boost::system::error_code& error) {
		if (!error) {
			hookup(sock, null_client);
			waitForTCPConnection();
		}
	});
}

void Server::hookup ( const std::shared_ptr< asio::ip::tcp::socket >& socket, const Config::Client& client)
{
	bithorded::Client::Ptr c = bithorded::Client::create(*this);
	auto conn = bithorde::Connection::create(ioSvc(), std::make_shared<bithorde::ConnectionStats>(_timerSvc), socket);
	c->setSecurity(client.key, (bithorde::CipherType)client.cipher);
	if (client.name.empty())
		c->hookup(conn);
	else
		c->connect(conn, client.name);
	clientConnected(c);
}

void Server::waitForLocalConnection()
{
	std::shared_ptr<asio::local::stream_protocol::socket> sock = std::make_shared<asio::local::stream_protocol::socket>(ioSvc());
	_localListener.async_accept(*sock, [=](const boost::system::error_code& error) {
		if (!error) {
			bithorded::Client::Ptr c = bithorded::Client::create(*this);
			c->hookup(bithorde::Connection::create(ioSvc(), std::make_shared<bithorde::ConnectionStats>(_timerSvc), sock));
			clientConnected(c);
			waitForLocalConnection();
		}
	});
}

void Server::inspect(management::InfoList& target) const
{
	target.append("router", _router);
	target.append("connections", _connections);
	if (_cache.enabled())
		target.append("cache", _cache);
	for (auto iter=_assetStores.begin(); iter!=_assetStores.end(); iter++) {
		const auto& store = **iter;
		target.append("source."+store.label(), store);
	}
}

void Server::clientConnected(const bithorded::Client::Ptr& client)
{
	Client::WeakPtr weak(client);
	client->authenticated.connect([=](bithorde::Client&, const std::string& peerName){
		if (Client::Ptr client = weak.lock()) {
			_connections.set(peerName, client);
			_router.onConnected(client);
		}
	});

	auto mut = client;
	client->disconnected.connect([=]() mutable {
		if (mut) {
			BOOST_LOG_SEV(serverLog, info) << "Disconnected: " << mut->peerName();
			_router.onDisconnected(mut);
			mut.reset();
		}
	});
}

const bithorded::Config::Client& Server::getClientConfig(const string& name)
{
	for (auto iter = _cfg.friends.begin(); iter != _cfg.friends.end(); iter++) {
		if (name == iter->name)
			return *iter;
	}
	for (auto iter = _cfg.clients.begin(); iter != _cfg.clients.end(); iter++) {
		if (name == iter->name)
			return *iter;
	}
	return null_client;
}

UpstreamRequestBinding::Ptr Server::asyncLinkAsset(const boost::filesystem::path& filePath)
{
	for (auto iter=_assetStores.begin(); iter != _assetStores.end(); iter++) {
		if (auto res = (*iter)->addAsset(filePath))
			return std::make_shared<UpstreamRequestBinding>(res);
	}
	return UpstreamRequestBinding::NONE;
}

UpstreamRequestBinding::Ptr Server::asyncFindAsset(const bithorde::BindRead& req)
{
	for (auto iter=_assetStores.begin(); iter != _assetStores.end(); iter++) {
		if (auto asset = (*iter)->findAsset(req))
			return asset;
	}

	if (auto asset = _cache.findAsset(req)) {
		return asset;
	} else
		return _router.findAsset(req);
}

UpstreamRequestBinding::Ptr Server::prepareUpload(uint64_t size)
{
	UpstreamRequestBinding::Ptr res;
	if (auto asset = _cache.prepareUpload(size))
		res = make_shared<UpstreamRequestBinding>(asset);
	return res;
}

