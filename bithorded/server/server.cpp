/*
    Copyright 2012 Ulrik Mikaelsson <ulrik.mikaelsson@gmail.com>

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

#include <boost/asio/placeholders.hpp>
#include <boost/filesystem.hpp>
#include <boost/make_shared.hpp>
#include <iostream>

#include <log4cplus/logger.h>
#include <log4cplus/loggingmacros.h>

#include "buildconf.hpp"
#include "client.hpp"
#include "config.hpp"

using namespace std;

namespace asio = boost::asio;
namespace fs = boost::filesystem;

using namespace bithorded;

namespace bithorded {
	log4cplus::Logger serverLog = log4cplus::Logger::getInstance("server");
}

BindError::BindError(bithorde::Status status):
	runtime_error("findAsset failed with " + bithorde::Status_Name(status)),
	status(status)
{
}

Server::Server(asio::io_service& ioSvc, Config& cfg) :
	_cfg(cfg),
	_ioSvc(ioSvc),
	_tcpListener(ioSvc),
	_localListener(ioSvc),
	_router(*this),
	_cache(ioSvc, _router, cfg.cacheDir, static_cast<intmax_t>(cfg.cacheSizeMB)*1024*1024)
{
	for (auto iter=_cfg.sources.begin(); iter != _cfg.sources.end(); iter++)
		_assetStores.push_back( unique_ptr<source::Store>(new source::Store(ioSvc, iter->root)) );

	for (auto iter=_cfg.friends.begin(); iter != _cfg.friends.end(); iter++)
		_router.addFriend(*iter);

	if (_cfg.tcpPort) {
		auto tcpPort = asio::ip::tcp::endpoint(boost::asio::ip::tcp::v4(), _cfg.tcpPort);
		_tcpListener.open(tcpPort.protocol());
		_tcpListener.set_option(boost::asio::ip::tcp::acceptor::reuse_address(true));
		_tcpListener.bind(tcpPort);
		_tcpListener.listen();

		waitForTCPConnection();
	}

	if (!_cfg.unixSocket.empty()) {
		if (fs::exists(_cfg.unixSocket))
			fs::remove(_cfg.unixSocket);
		auto localPort = asio::local::stream_protocol::endpoint(_cfg.unixSocket);
		_localListener.open(localPort.protocol());
		_localListener.set_option(boost::asio::local::stream_protocol::acceptor::reuse_address(true));
		_localListener.bind(localPort);
		_localListener.listen(4);

		waitForLocalConnection();
	}

	LOG4CPLUS_INFO(serverLog, "Server started, version " << bithorde::build_version);
}

asio::io_service& Server::ioService()
{
	return _ioSvc;
}

void Server::waitForTCPConnection()
{
	boost::shared_ptr<asio::ip::tcp::socket> sock = boost::make_shared<asio::ip::tcp::socket>(_ioSvc);
	_tcpListener.async_accept(*sock, boost::bind(&Server::onTCPConnected, this, sock, asio::placeholders::error));
}

void Server::onTCPConnected(boost::shared_ptr< asio::ip::tcp::socket >& socket, const boost::system::error_code& ec)
{
	if (!ec) {
		onTCPConnected(socket);
		waitForTCPConnection();
	}
}

void Server::onTCPConnected ( boost::shared_ptr< asio::ip::tcp::socket >& socket )
{
	bithorded::Client::Ptr c = bithorded::Client::create(*this);
	c->connect(bithorde::Connection::create(_ioSvc, socket));
	clientConnected(c);
}

void Server::waitForLocalConnection()
{
	boost::shared_ptr<asio::local::stream_protocol::socket> sock = boost::make_shared<asio::local::stream_protocol::socket>(_ioSvc);
	_localListener.async_accept(*sock, boost::bind(&Server::onLocalConnected, this, sock, asio::placeholders::error));
}

void Server::onLocalConnected(boost::shared_ptr< boost::asio::local::stream_protocol::socket >& socket, const boost::system::error_code& ec)
{
	if (!ec) {
		bithorded::Client::Ptr c = bithorded::Client::create(*this);
		c->connect(bithorde::Connection::create(_ioSvc, socket));
		clientConnected(c);
		waitForLocalConnection();
	}
}

void Server::clientConnected(const bithorded::Client::Ptr& client)
{
	// When storing a client-copy in the bound reference, we make sure the Client isn't
	// destroyed until the disconnected signal calls clientDisconnected, which releases
	// the reference
	client->disconnected.connect(boost::bind(&Server::clientDisconnected, this, client));
	client->authenticated.connect(boost::bind(&Server::clientAuthenticated, this, Client::WeakPtr(client)));
}

void Server::clientAuthenticated(const bithorded::Client::WeakPtr& client_) {
	if (Client::Ptr client = client_.lock())
		_router.onConnected(client);
}

void Server::clientDisconnected(bithorded::Client::Ptr& client)
{
	LOG4CPLUS_INFO(serverLog, "Disconnected: " << client->peerName());
	_router.onDisconnected(client);
	// Will destroy the client, unless others are holding references.
	client.reset();
}

IAsset::Ptr Server::async_linkAsset(const boost::filesystem::path& filePath)
{
	for (auto iter=_assetStores.begin(); iter != _assetStores.end(); iter++) {
		auto res = (*iter)->addAsset(filePath);
		if (res)
			return res;
	}
	return ASSET_NONE;
}

IAsset::Ptr Server::async_findAsset(const bithorde::BindRead& req)
{
	for (auto iter=_assetStores.begin(); iter != _assetStores.end(); iter++) {
		IAsset::Ptr asset((*iter)->findAsset(req.ids()));
		if (asset)
			return asset;
	}

	if (auto asset = _cache.findAsset(req.ids()))
		return asset;
	else
		return _router.findAsset(req);
}

IAsset::Ptr Server::prepareUpload(uint64_t size)
{
	return _cache.prepareUpload(size);
}

