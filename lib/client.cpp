#include "client.h"

#include <boost/asio/placeholders.hpp>
#include <boost/assert.hpp>
#include <boost/bind.hpp>
#include <boost/date_time/posix_time/posix_time.hpp>
#include <boost/lexical_cast.hpp>
#include <boost/regex.hpp>
#include <iostream>
#include <string.h>

#include "random.h"

const static boost::posix_time::millisec DEFAULT_ASSET_TIMEOUT(500);

using namespace std;
namespace asio = boost::asio;

using namespace bithorde;

AssetBinding::AssetBinding(Client* client, Asset* asset, Asset::Handle handle) :
	_client(client),
	_asset(asset),
	_handle(handle),
	_statusTimer(client->_ioSvc)
{
}

Asset* AssetBinding::asset() const
{
	return _asset;
}

ReadAsset* AssetBinding::readAsset() const
{
	return dynamic_cast<ReadAsset*>(_asset);
}

void AssetBinding::close()
{
	_asset = NULL;
	setTimer(DEFAULT_ASSET_TIMEOUT);
}

void AssetBinding::setTimer(const boost::posix_time::time_duration& timeout)
{
	_statusTimer.expires_from_now(timeout);
	_statusTimer.async_wait(boost::bind(&AssetBinding::onTimeout, shared_from_this(), boost::asio::placeholders::error));
}

void AssetBinding::clearTimer()
{
	_statusTimer.cancel();
}

void AssetBinding::onTimeout(const boost::system::error_code& error)
{
	if (error)
		return;
	if (_asset) {
		bithorde::AssetStatus msg;
		msg.set_status(bithorde::Status::TIMEOUT);
		_asset->handleMessage(msg);
	} else {
		_client->informBound(*this, rand64(), DEFAULT_ASSET_TIMEOUT.total_milliseconds());
		setTimer(DEFAULT_ASSET_TIMEOUT);
	}
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
	static const boost::regex host_port_regex("(\\w+):(\\d+)");
        boost::smatch res;
	if (spec[0] == '/') {
		asio::local::stream_protocol::endpoint ep(spec);
		connect(ep);
	} else if (boost::regex_match(spec, res, host_port_regex)) {
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
		ReadAsset* asset = iter->second->readAsset();
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

bool Client::sendMessage(Connection::MessageType type, const google::protobuf::Message& msg, const Message::Deadline& expires)
{
	BOOST_ASSERT(_connection);

	return _connection->sendMessage(type, msg, expires, false);
}

void Client::sayHello() {
	bithorde::HandShake h;
	h.set_protoversion(2);
	h.set_name(_myName);

	sendMessage(Connection::MessageType::HandShake, h);
}

void Client::onIncomingMessage(Connection::MessageType type, ::google::protobuf::Message& msg)
{
	switch (type) {
	case Connection::MessageType::HandShake: return onMessage((bithorde::HandShake&) msg);
	case Connection::MessageType::BindRead: return onMessage((bithorde::BindRead&) msg);
	case Connection::MessageType::AssetStatus: return onMessage((bithorde::AssetStatus&) msg);
	case Connection::MessageType::ReadRequest: return onMessage((bithorde::Read::Request&) msg);
	case Connection::MessageType::ReadResponse: return onMessage((bithorde::Read::Response&) msg);
	case Connection::MessageType::BindWrite: return onMessage((bithorde::BindWrite&) msg);
	case Connection::MessageType::DataSegment: return onMessage((bithorde::DataSegment&) msg);
	case Connection::MessageType::HandShakeConfirmed: return onMessage((bithorde::HandShakeConfirmed&) msg);
	case Connection::MessageType::Ping: return onMessage((bithorde::Ping&) msg);
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
			BOOST_ASSERT(iter->second->readAsset());
			informBound(*iter->second, rand64(), DEFAULT_ASSET_TIMEOUT.total_milliseconds());
		}
			
		authenticated(_peerName);
	}
}

void Client::onMessage(bithorde::BindRead & msg) {
	cerr << "unsupported: handling BindRead" << endl;
	bithorde::AssetStatus resp;
	resp.set_handle(msg.handle());
	resp.set_status(ERROR);
	sendMessage(Connection::MessageType::AssetStatus, resp);
}

void Client::onMessage(const bithorde::AssetStatus & msg) {
	if (!msg.has_handle())
		return;
	Asset::Handle handle = msg.handle();
	if (_assetMap.count(handle)) {
		AssetBinding& a = *_assetMap[handle];
		a.clearTimer();
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
	sendMessage(Connection::MessageType::ReadResponse, resp);
}

void Client::onMessage(const bithorde::Read::Response & msg) {
	if (_requestIdMap.count(msg.reqid())) {
		Asset::Handle assetHandle = _requestIdMap[msg.reqid()];
		releaseRPCRequest(msg.reqid());
		if (_assetMap.count(assetHandle)) {
			Asset* a = _assetMap[assetHandle]->asset();
			if (a) {
				a->handleMessage(msg);
			} else {
				cerr << "WARNING: ReadResponse " << msg.reqid() << " for handle being closed " << assetHandle << endl;
			}
		} else {
			cerr << "WARNING: ReadResponse " << msg.reqid() << " for unmapped handle " << assetHandle << endl;
		}
	} else {
		cerr << "WARNING: ReadResponse with unknown requestId" << endl;
	}
}

void Client::onMessage(const bithorde::BindWrite & msg) {
	cerr << "unsupported: handling BindWrite" << endl;
	bithorde::AssetStatus resp;
	resp.set_handle(msg.handle());
	resp.set_status(ERROR);
	sendMessage(Connection::MessageType::AssetStatus, resp);
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
	_connection->sendMessage(Connection::MessageType::Ping, reply, Message::NEVER, false);
}

bool Client::bind(ReadAsset &asset) {
	return bind(asset, rand64(), DEFAULT_ASSET_TIMEOUT.total_milliseconds());
}

bool Client::bind(ReadAsset& asset, uint64_t uuid, int timeout_ms) {
	if (!asset.isBound()) {
		BOOST_ASSERT(asset._handle < 0);
		BOOST_ASSERT(asset.requestIds().size() > 0);
		asset._handle = _handleAllocator.allocate();
		BOOST_ASSERT(asset._handle > 0);
		BOOST_ASSERT(_assetMap.count(asset._handle) == 0);
		auto& bind = _assetMap[asset._handle];
		bind = boost::make_shared<AssetBinding>(this, &asset, asset._handle);
		bind->setTimer(boost::posix_time::millisec(timeout_ms));
	}

	return informBound(*_assetMap[asset._handle], uuid, timeout_ms);
}

bool Client::bind(UploadAsset & asset)
{
	BOOST_ASSERT(asset._client.get() == this);
	BOOST_ASSERT(asset._handle < 0);
	BOOST_ASSERT(asset.size() > 0);
	asset._handle = _handleAllocator.allocate();
	auto& bind = _assetMap[asset._handle];
	bind = boost::make_shared<AssetBinding>(this, &asset, asset._handle);
	bind->setTimer(DEFAULT_ASSET_TIMEOUT);
	bithorde::BindWrite msg;
	msg.set_handle(asset._handle);
	msg.set_size(asset.size());
	const auto& link = asset.link();
	if (!link.empty())
		msg.set_linkpath(link.string());
	return _connection->sendMessage(Connection::MessageType::BindWrite, msg, Message::NEVER, false);
}

bool Client::release(Asset & asset)
{
	BOOST_ASSERT(asset.isBound());
	BOOST_ASSERT(_assetMap.find(asset._handle) != _assetMap.end());

	auto& binding = *_assetMap[asset._handle];

	// Leave binding dangling, so it won't be reused until confirmation has been received from the other side.
	binding.close();
	asset._handle = -1;

	if (_connection)
		return informBound(binding, rand64(), DEFAULT_ASSET_TIMEOUT.total_milliseconds());
	else
		return true; // Since connection is down, other side should not have the bound state as it is.
}

bool Client::informBound(const AssetBinding& asset, uint64_t uuid, int timeout_ms)
{
	BOOST_ASSERT(asset._handle >= 0);

	if (!_connection)
		return false;

	bithorde::BindRead msg;
	msg.set_handle(asset._handle);

	ReadAsset * readAsset = asset.readAsset();
	if (readAsset)
		msg.mutable_ids()->CopyFrom(readAsset->requestIds());
	msg.set_timeout(timeout_ms);
	msg.set_uuid(uuid);

	return _connection->sendMessage(Connection::MessageType::BindRead, msg, Message::in(timeout_ms), true);
}

int Client::allocRPCRequest(Asset::Handle asset)
{
	int res = _rpcIdAllocator.allocate();
	_requestIdMap[res] = asset;
	return res;
}

void Client::releaseRPCRequest(int reqId)
{
	if (_requestIdMap.erase(reqId))
		_rpcIdAllocator.free(reqId);
}
