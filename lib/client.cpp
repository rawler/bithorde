#include "client.h"

#include <iostream>
#include <stdlib.h>
#include <string.h>

#include <boost/assert.hpp>
#include <boost/bind.hpp>
#include <boost/lexical_cast.hpp>
#include <boost/xpressive/xpressive.hpp>

#define DEFAULT_ASSET_TIMEOUT 4000

using namespace std;
namespace asio = boost::asio;
namespace xpressive = boost::xpressive;

uint64_t rand64() {
	// TODO: improve seeding throuh srandomdev
	return (((uint64_t)rand()) << 32) | rand();
}

Client::Client(asio::io_service& ioSvc, string myName) :
	_ioSvc(ioSvc),
	_connection(),
	_myName(myName),
	_handleAllocator(1),
	_rpcIdAllocator(1),
	_protoVersion(0)
{
}

void Client::connect(Connection::Pointer newConn) {
	BOOST_ASSERT(!_connection);

	_connection = newConn;
	_connection->message.connect(boost::bind(&Client::onIncomingMessage, this, _1, _2));
	_connection->writable.connect(writable);
	_connection->disconnected.connect(boost::bind(&Client::onDisconnected, this));

	sayHello();
}

void Client::connect(asio::ip::tcp::endpoint& ep) {
	connect(Connection::create(_ioSvc, ep));
}

void Client::connect(asio::local::stream_protocol::endpoint& ep) {
	connect(Connection::create(_ioSvc, ep));
}

void Client::connect(string spec) {
	xpressive::sregex host_port_regex = xpressive::sregex::compile("(\\w+):(\\d+)");
	xpressive::smatch res;
	if (spec[0] == '/') {
		asio::local::stream_protocol::endpoint ep(spec);
		connect(ep);
	} else if (xpressive::regex_match(spec, res, host_port_regex)) {
		asio::ip::tcp::resolver resolver(_ioSvc);
		asio::ip::tcp::resolver::query q(res[1], res[2]);
		asio::ip::tcp::resolver::iterator iter = resolver.resolve(q);
		if (iter != asio::ip::tcp::resolver::iterator()) {
			asio::ip::tcp::endpoint ep(iter->endpoint());
			connect(ep);
		}
	} else {
		throw string("Failed to parse: " + spec);
	}
}

void Client::onDisconnected() {
	_connection.reset();
	for (auto iter=_assetMap.begin(); iter != _assetMap.end(); iter++) {
		ReadAsset* asset = dynamic_cast<ReadAsset*>(iter->second);
		if (!asset) {
			_handleAllocator.free(iter->first);
			_assetMap.erase(iter);
		}
	}
	disconnected();
}

bool Client::sendMessage(Connection::MessageType type, const::google::protobuf::Message &msg)
{
	BOOST_ASSERT(_connection);

	return _connection->sendMessage(type, msg);
}

void Client::sayHello() {
	bithorde::HandShake h;
	h.set_protoversion(2);
	h.set_name(_myName);

	sendMessage(Connection::HandShake, h);
}

void Client::onIncomingMessage(Connection::MessageType type, ::google::protobuf::Message& msg)
{
	switch (type) {
	case Connection::HandShake: return onMessage((bithorde::HandShake&) msg);
	case Connection::BindRead: return onMessage((bithorde::BindRead&) msg);
	case Connection::AssetStatus: return onMessage((bithorde::AssetStatus&) msg);
	case Connection::ReadRequest: return onMessage((bithorde::Read::Request&) msg);
	case Connection::ReadResponse: return onMessage((bithorde::Read::Response&) msg);
	case Connection::BindWrite: return onMessage((bithorde::BindWrite&) msg);
	case Connection::DataSegment: return onMessage((bithorde::DataSegment&) msg);
	case Connection::HandShakeConfirmed: return onMessage((bithorde::HandShakeConfirmed&) msg);
	case Connection::Ping: return onMessage((bithorde::Ping&) msg);
	}
}

void Client::onMessage(const bithorde::HandShake &msg)
{
	if (msg.protoversion() >= 2) {
		_protoVersion = 2;
	} else {
		// TODO: LogFail and disconnect
		return;
	}

	_peerName = msg.name();

	if (msg.has_challenge()) {
		// Setup encryption
	} else {
		for (auto iter = _assetMap.begin(); iter != _assetMap.end(); iter++) {
			ReadAsset* asset = dynamic_cast<ReadAsset*>(iter->second);
			BOOST_ASSERT(iter->second);
			informBound(*asset);
		}
			
		authenticated(_peerName);
	}
}

void Client::onMessage(const bithorde::BindRead & msg) {}
void Client::onMessage(const bithorde::AssetStatus & msg) {
	if (!msg.has_handle())
		return;
	Asset::Handle handle = msg.handle();
	if (_assetMap.count(handle)) {
		Asset* a = _assetMap[handle];
		if (a) {
			a->handleMessage(msg);
		} else if (msg.status() != bithorde::Status::SUCCESS) {
			_assetMap.erase(handle);
			_handleAllocator.free(handle);
		} else {
			cerr << "WARNING: Status OK recieved for Asset supposedly closed or re-written." << endl;
		}
	} else {
		cerr << "WARNING: AssetStatus for unmapped handle" << endl;
	}
}

void Client::onMessage(const bithorde::Read::Request & msg) {}
void Client::onMessage(const bithorde::Read::Response & msg) {
	Asset::Handle assetHandle = _requestIdMap[msg.reqid()];
	if (_assetMap.count(assetHandle)) {
		Asset* a = _assetMap[assetHandle];
		a->handleMessage(msg);
	} else {
		cerr << "WARNING: ReadResponse " << msg.reqid() << msg.has_reqid() << " for unmapped handle" << endl;
		// TODO: Log error
	}
}

void Client::onMessage(const bithorde::BindWrite & msg) {}
void Client::onMessage(const bithorde::DataSegment & msg) {}
void Client::onMessage(const bithorde::HandShakeConfirmed & msg) {}
void Client::onMessage(const bithorde::Ping & msg) {
	bithorde::Ping reply;
	cerr << "Was here" << endl;
	_connection->sendMessage(Connection::Ping, reply);
}

bool Client::bind(ReadAsset &asset) {
	BOOST_ASSERT(asset._handle < 0);
	BOOST_ASSERT(asset.requestIds().size() > 0);
	asset._handle = _handleAllocator.allocate();
	BOOST_ASSERT(asset._handle > 0);
	_assetMap[asset._handle] = &asset;

	return informBound(asset);
}

bool Client::bind(UploadAsset & asset)
{
	// TODO: BOOST_ASSERT(asset._client == this);
	BOOST_ASSERT(asset._handle < 0);
	BOOST_ASSERT(asset.size() > 0);
	asset._handle = _handleAllocator.allocate();
	_assetMap[asset._handle] = &asset;
	bithorde::BindWrite msg;
	msg.set_handle(asset._handle);
	msg.set_size(asset.size());
	return _connection->sendMessage(Connection::BindWrite, msg);
}

bool Client::release(Asset & asset)
{
	BOOST_ASSERT(asset.isBound());
	bithorde::BindRead msg;
	msg.set_handle(asset._handle);
	msg.set_timeout(DEFAULT_ASSET_TIMEOUT);
	msg.set_uuid(rand64());

	_assetMap[asset._handle] = NULL;
	asset._handle = -1;

	return _connection->sendMessage(Connection::BindRead, msg);
}

bool Client::informBound(const ReadAsset& asset)
{
	BOOST_ASSERT(_connection);
	BOOST_ASSERT(asset._handle >= 0);

	bithorde::BindRead msg;
	msg.set_handle(asset._handle);

	auto ids = asset.requestIds();
	for (auto iter = ids.begin(); iter < ids.end(); iter++) {
		ReadAsset::Identifier& id = *iter;
		bithorde::Identifier * bhId = msg.add_ids();
		bhId->set_type(id.first);
		bhId->set_id(id.second.data(), id.second.size());
	}
	msg.set_timeout(DEFAULT_ASSET_TIMEOUT);
	msg.set_uuid(rand64());
	return _connection->sendMessage(Connection::BindRead, msg);
}

int Client::allocRPCRequest(Asset::Handle asset)
{
	int res = _rpcIdAllocator.allocate();
	_requestIdMap[res] = asset;
	return res;
}

void Client::releaseRPCRequest(int reqId)
{
	_requestIdMap.erase(reqId);
	_rpcIdAllocator.free(reqId);
}
