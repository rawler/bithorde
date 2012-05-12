#include "client.h"

#include <boost/assert.hpp>
#include <boost/bind.hpp>
#include <boost/lexical_cast.hpp>
#include <boost/xpressive/xpressive.hpp>
#include <iostream>
#include <string.h>

#include "random.h"

#define DEFAULT_ASSET_TIMEOUT 4000

using namespace std;
namespace asio = boost::asio;
namespace xpressive = boost::xpressive;

using namespace bithorde;

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

	_rpcIdAllocator.reset();
	_connection = newConn;

	_messageConnection = _connection->message.connect(Connection::MessageSignal::slot_type(&Client::onIncomingMessage, this, _1, _2));
	_writableConnection = _connection->writable.connect(writable);
	_disconnectedConnection = _connection->disconnected.connect(Connection::VoidSignal::slot_type(&Client::onDisconnected, this));

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
		if (asset) {
			bithorde::AssetStatus s;
			s.set_status(bithorde::DISCONNECTED);
			asset->statusUpdate(s);
		} else {
			_handleAllocator.free(iter->first);
			_assetMap.erase(iter);
		}
	}
	disconnected();
}

bool Client::isConnected()
{
	return _connection;
}

const std::string& Client::peerName()
{
	return _peerName;
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
		cerr << "Only Protocol-version 2 or higer supported" << endl;
		_connection->close();
		_connection.reset();
		return;
	}

	_peerName = msg.name();

	if (msg.has_challenge()) {
		cerr << "Challenge required" << endl;
		// Setup encryption
	} else {
		for (auto iter = _assetMap.begin(); iter != _assetMap.end(); iter++) {
			ReadAsset* asset = dynamic_cast<ReadAsset*>(iter->second);
			BOOST_ASSERT(iter->second);
			informBound(*asset, rand64());
		}
			
		authenticated(_peerName);
	}
}

void Client::onMessage(bithorde::BindRead & msg) {
	cerr << "unsupported: handling BindRead" << endl;
	bithorde::AssetStatus resp;
	resp.set_handle(msg.handle());
	resp.set_status(ERROR);
	sendMessage(bithorde::Connection::AssetStatus, resp);
}
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
		cerr << "WARNING: AssetStatus " << bithorde::Status_Name(msg.status()) << " for unmapped handle" << endl;
	}
}

void Client::onMessage(const bithorde::Read::Request & msg) {
	cerr << "unsupported: handling Read-Requests" << endl;
	bithorde::Read::Response resp;
	resp.set_reqid(msg.reqid());
	resp.set_status(ERROR);
	sendMessage(bithorde::Connection::ReadResponse, resp);
}

void Client::onMessage(const bithorde::Read::Response & msg) {
	Asset::Handle assetHandle = _requestIdMap[msg.reqid()];
	if (_assetMap.count(assetHandle)) {
		Asset* a = _assetMap[assetHandle];
		a->handleMessage(msg);
	} else {
		cerr << "WARNING: ReadResponse " << msg.reqid() << msg.has_reqid() << " for unmapped handle" << endl;
	}
}

void Client::onMessage(const bithorde::BindWrite & msg) {
	cerr << "unsupported: handling BindWrite" << endl;
	bithorde::AssetStatus resp;
	resp.set_handle(msg.handle());
	resp.set_status(ERROR);
	sendMessage(bithorde::Connection::AssetStatus, resp);
}
void Client::onMessage(const bithorde::DataSegment & msg) {
	cerr << "unsupported: handling DataSegment-pushes" << endl;
	_connection->close();
}
void Client::onMessage(const bithorde::HandShakeConfirmed & msg) {
	cerr << "unsupported: challenge-response handshakes" << endl;
	_connection->close();
}
void Client::onMessage(const bithorde::Ping & msg) {
	bithorde::Ping reply;
	_connection->sendMessage(Connection::Ping, reply);
}

bool Client::bind(ReadAsset &asset) {
	return bind(asset, rand64());
}

bool Client::bind(ReadAsset &asset, uint64_t uuid) {
	if (!asset.isBound()) {
		BOOST_ASSERT(asset._handle < 0);
		BOOST_ASSERT(asset.requestIds().size() > 0);
		asset._handle = _handleAllocator.allocate();
		BOOST_ASSERT(asset._handle > 0);
		BOOST_ASSERT(_assetMap.count(asset._handle) == 0);
		_assetMap[asset._handle] = &asset;
	}

	return informBound(asset, uuid);
}

bool Client::bind(UploadAsset & asset)
{
	BOOST_ASSERT(asset._client.get() == this);
	BOOST_ASSERT(asset._handle < 0);
	BOOST_ASSERT(asset.size() > 0);
	asset._handle = _handleAllocator.allocate();
	_assetMap[asset._handle] = &asset;
	bithorde::BindWrite msg;
	msg.set_handle(asset._handle);
	msg.set_size(asset.size());
	const auto& link = asset.link();
	if (!link.empty())
		msg.set_linkpath(link.string());
	return _connection->sendMessage(Connection::BindWrite, msg);
}

bool Client::release(Asset & asset)
{
	BOOST_ASSERT(asset.isBound());
	bithorde::BindRead msg;
	msg.set_handle(asset._handle);
	msg.set_timeout(DEFAULT_ASSET_TIMEOUT);
	msg.set_uuid(rand64());

	// Leave handle dangling, so it won't be reused until confirmation has been received from the other side.
	_assetMap[asset._handle] = NULL;
	asset._handle = -1;

	return _connection->sendMessage(Connection::BindRead, msg);
}

bool Client::informBound(const ReadAsset& asset, uint64_t uuid)
{
	BOOST_ASSERT(_connection);
	BOOST_ASSERT(asset._handle >= 0);

	if (!_connection)
		return false;

	bithorde::BindRead msg;
	msg.set_handle(asset._handle);

	msg.mutable_ids()->CopyFrom(asset.requestIds());
	msg.set_timeout(DEFAULT_ASSET_TIMEOUT);
	msg.set_uuid(uuid);
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
