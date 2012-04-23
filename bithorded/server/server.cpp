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

#include "client.hpp"
#include "config.hpp"

#include <glog/logging.h>

using namespace std;

namespace asio = boost::asio;
namespace fs = boost::filesystem;

using namespace bithorded;

Server::Server(asio::io_service& ioSvc, Config& cfg) :
	_cfg(cfg),
	_ioSvc(ioSvc),
	_tcpListener(ioSvc),
	_localListener(ioSvc)
{
	for (auto iter=_cfg.sources.begin(); iter != _cfg.sources.end(); iter++) {
		_assetStores.push_back( unique_ptr<LinkedAssetStore>(new LinkedAssetStore(ioSvc, iter->root)) );
	}

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
		bithorded::Client::Pointer c = bithorded::Client::create(*this, _cfg.nodeName);
		c->connect(bithorde::Connection::create(_ioSvc, socket));
		clientConnected(c);
		waitForTCPConnection();
	}
}

void Server::waitForLocalConnection()
{
	boost::shared_ptr<asio::local::stream_protocol::socket> sock = boost::make_shared<asio::local::stream_protocol::socket>(_ioSvc);
	_localListener.async_accept(*sock, boost::bind(&Server::onLocalConnected, this, sock, asio::placeholders::error));
}

void Server::onLocalConnected(boost::shared_ptr< boost::asio::local::stream_protocol::socket >& socket, const boost::system::error_code& ec)
{
	if (!ec) {
		bithorded::Client::Pointer c = bithorded::Client::create(*this, _cfg.nodeName);
		c->connect(bithorde::Connection::create(_ioSvc, socket));
		clientConnected(c);
		waitForLocalConnection();
	}
}

void Server::clientConnected(const bithorde::Client::Pointer& client)
{
	// When storing a client-copy in the bound reference, we make sure the Client isn't
	// destroyed until the disconnected signal calls clientDisconnected, which releases
	// the reference
	client->disconnected.connect(boost::bind(&Server::clientDisconnected, this, client));
}

void Server::clientDisconnected(bithorde::Client::Pointer& client)
{
	LOG(INFO) << "Disconnected: " << client->peerName() << endl;
	// Will destroy the client, unless others are holding references.
	client.reset();
}

bool Server::linkAsset(const boost::filesystem3::path& filePath, LinkedAssetStore::ResultHandler resultHandler)
{
	for (auto iter=_assetStores.begin(); iter != _assetStores.end(); iter++) {
		bool res = (*iter)->addAsset(filePath, resultHandler);
		if (res)
			return res;
	}
	return false;
}

void Server::async_findAsset( const bithorde::BindRead& req, Asset::Target tgt)
{
	for (auto iter=_assetStores.begin(); iter != _assetStores.end(); iter++) {
		Asset::Ptr asset((*iter)->findAsset(req.ids()));
		if (asset)
			return tgt(asset);
	}

	return tgt(Asset::Ptr());
}
