#include "client.h"

#include "keepalive.hpp"

#include <boost/algorithm/string.hpp>
#include <boost/asio/placeholders.hpp>
#include <boost/assert.hpp>
#include <boost/date_time/posix_time/posix_time.hpp>
#include <boost/lexical_cast.hpp>
#include <chrono>
#include <functional>
#include <iostream>
#include <memory>
#include <string.h>

#include <crypto++/hmac.h>
#include <crypto++/sha.h>
#include <google/protobuf/descriptor.h>

#include "random.h"
#include "weak_fn.hpp"

const static int LOTS_OF_MILLISECONDS(2^30);
const size_t MAX_BYTES_ALLOCATED(512*1024);

using namespace std;
namespace asio = boost::asio;
namespace ptime = boost::posix_time;

using namespace bithorde;

namespace bithorde {

struct CipherConfig {
	CipherType type;
	string iv;

	CipherConfig(CipherType type, const string& iv) :
		type(type), iv(iv) {}
};
}

AssetBinding::AssetBinding(Client* client, Asset* asset, Asset::Handle handle) :
	_client(client),
	_asset(asset),
	_handle(handle),
	_statusTimer(*client->_timerSvc, std::bind(&AssetBinding::onTimeout, this))
{
	_opened_at = boost::posix_time::microsec_clock::universal_time();
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
	setTimer(CLOSE_TIMEOUT);
}

void AssetBinding::setTimer(const boost::posix_time::time_duration& timeout)
{
	_statusTimer.arm(timeout);
}

void AssetBinding::clearTimer()
{
	_statusTimer.clear();
}

void AssetBinding::orphaned()
{
	clearTimer();
	_client = NULL;
}

void AssetBinding::onTimeout()
{
	if (_asset) {
		bithorde::AssetStatus msg;
		msg.set_status(bithorde::Status::TIMEOUT);
		_asset->handleMessage(msg);
	} else if (_client) {
		if (_client->informBound(*this, LOTS_OF_MILLISECONDS)) {
			setTimer(CLOSE_TIMEOUT);
		} else {
			cerr << "Warning: informBound failed in AssetBinding::onTimeout." << endl;
		}
	} else {
		cerr << "Warning: onTimeout() for stale AssetBinding" << endl;
	}
}

Client::Client(asio::io_context& ioCtx, string myName) :
	_ioCtx(ioCtx),
	_timerSvc(new TimerService(ioCtx)),
	_state(Connecting),
	_myName(myName),
	_handleAllocator(1),
	_rpcIdAllocator(1),
	_protoVersion(0),
	_bytesAllocated(0),
	assetResponseTime(0.98, "ms")
{
}

Client::~Client()
{
	for (auto iter = _assetMap.begin(); iter != _assetMap.end(); iter++) {
		iter->second->orphaned();
	}
}

Client::State Client::state()
{
	return _state;
}

const TimerService::Ptr& Client::timerService()
{
	return _timerSvc;
}

void Client::setSecurity(const string& key, CipherType cipher)
{
	if (_state & (SaidHello | SentAuth | GotAuth) )
		throw std::runtime_error("Client were in wrong state for setSecurity");
	_key = key;
	_sendCipher.reset(new CipherConfig(cipher, secureRandomBytes(key.size())));
}

void Client::hookup(Connection::Pointer newConn)
{
	BOOST_ASSERT(!_connection);
	BOOST_ASSERT(_state == Connecting);
	addStateFlag(Connected);

	stats = newConn->stats();

	_rpcIdAllocator.reset();
	_connection = newConn;

	_connection->setCallback(std::bind(&Client::onIncomingMessage, this, std::placeholders::_1, std::placeholders::_2));
	_writableConnection = _connection->writable.connect(writable);
	_disconnectedConnection = _connection->disconnected.connect(Connection::VoidSignal::slot_type(&Client::onDisconnected, this));
}

void Client::connect(Connection::Pointer newConn, const std::string& expectedPeer) {
	_peerName = expectedPeer;
	newConn->setLogTag(_peerName);
	hookup(newConn);
	sayHello();
}

void Client::connect(asio::ip::tcp::endpoint& ep) {
	stats.reset(new ConnectionStats(_timerSvc));
	connect(Connection::create(_ioCtx, stats, ep));
}

void Client::connect(asio::local::stream_protocol::endpoint& ep) {
	stats.reset(new ConnectionStats(_timerSvc));
	connect(Connection::create(_ioCtx, stats, ep));
}

void Client::connect(const string& spec) {
	vector<string> host_port;
	if (spec[0] == '/') {
		asio::local::stream_protocol::endpoint ep(spec);
		connect(ep);
	} else if (boost::algorithm::split(host_port, spec, boost::algorithm::is_any_of(":"), boost::algorithm::token_compress_on).size() == 2) {
		asio::ip::tcp::resolver resolver(_ioCtx);
		asio::ip::tcp::resolver::query q(host_port[0], host_port[1]);
		asio::ip::tcp::resolver::iterator iter = resolver.resolve(q);
		if (iter != asio::ip::tcp::resolver::iterator()) {
			asio::ip::tcp::endpoint ep(iter->endpoint());
			connect(ep);
		}
	} else {
		throw string("Failed to parse: " + spec);
	}
}

void Client::close()
{
	if (_connection)
		_connection->close();
}

void Client::onDisconnected() {
	_connection.reset();
	_state = Connecting;
	for (auto iter=_assetMap.begin(); iter != _assetMap.end();) {
		auto current = iter++;
		if (auto binding = current->second) {
			binding->clearTimer();
			if (auto asset = binding->readAsset()) {
				bithorde::AssetStatus s;
				s.set_status(bithorde::DISCONNECTED);
				asset->statusUpdate(s);
			} else {
				_handleAllocator.free(current->first);
				_assetMap.erase(current);
			}
		}
	}
	disconnected();
}

bool Client::isConnected()
{
	return _connection.get();
}

const std::string& Client::peerName()
{
	return _peerName;
}

const Client::AssetMap& Client::clientAssets() const
{
	return _assetMap;
}

bool Client::sendMessage(Connection::MessageType type, const google::protobuf::Message& msg, const bithorde::Message::Deadline& expires, bool prioritized)
{
	if (_connection)
		return _connection->sendMessage(type, msg, expires, prioritized);
	else
		return false;
}

void Client::allocateBytes ( size_t bytes ) {
	Client::WeakPtr self(shared_from_this());
	_ioCtx.post(std::bind(boost::weak_fn(&Client::trackAllocation, self), bytes));
}

void Client::freeBytes ( size_t bytes ) {
	Client::WeakPtr self(shared_from_this());
	_ioCtx.post(std::bind(boost::weak_fn(&Client::trackAllocation, self), -bytes));
}

void Client::trackAllocation ( ssize_t change ) {
	_bytesAllocated += change;
	if (_connection) {
		_connection->setListening(_bytesAllocated < MAX_BYTES_ALLOCATED);
	}
}

size_t Client::bytesAllocated() const {
	return _bytesAllocated;
}

void Client::sayHello() {
	if (_state & SaidHello)
		throw std::runtime_error("Already sent HandShake");
	bithorde::HandShake h;
	h.set_protoversion(2);
	h.set_name(_myName);
	_sentChallenge.clear();
	if (_key.size()) {
		_sentChallenge = secureRandomBytes(16);
		h.set_challenge(_sentChallenge);
	}
	sendMessage(Connection::MessageType::HandShake, h);
	addStateFlag(SaidHello);
}

void Client::onIncomingMessage(Connection::MessageType type, const ::google::protobuf::Message& msg)
{
	if (_state == Authenticated) {
		switch (type) {
		case Connection::MessageType::BindRead:
			return onMessage(std::make_shared< MessageContext<bithorde::BindRead> >(shared_from_this(), (bithorde::BindRead&) msg));
		case Connection::MessageType::AssetStatus:
			return onMessage(std::make_shared< MessageContext<bithorde::AssetStatus> >(shared_from_this(), (bithorde::AssetStatus&) msg));
		case Connection::MessageType::ReadRequest:
			return onMessage(std::make_shared< MessageContext<bithorde::Read::Request> >(shared_from_this(), (bithorde::Read::Request&) msg));
		case Connection::MessageType::ReadResponse:
			return onMessage(std::make_shared< MessageContext<bithorde::Read::Response> >(shared_from_this(), (bithorde::Read::Response&) msg));
		case Connection::MessageType::BindWrite:
			return onMessage(std::make_shared< MessageContext<bithorde::BindWrite> >(shared_from_this(), (bithorde::BindWrite&) msg));
		case Connection::MessageType::DataSegment:
			return onMessage(std::make_shared< MessageContext<bithorde::DataSegment> >(shared_from_this(), (bithorde::DataSegment&) msg));
		case Connection::MessageType::Ping:
			return onMessage(std::make_shared< MessageContext<bithorde::Ping> >(shared_from_this(), (bithorde::Ping&) msg));
		default: break;
		}
	} else {
		switch (type) {
		case Connection::MessageType::HandShake:
			return onMessage(std::make_shared< MessageContext<bithorde::HandShake> >(shared_from_this(), (bithorde::HandShake&) msg));
		case Connection::MessageType::HandShakeConfirmed:
			return onMessage(std::make_shared< MessageContext<bithorde::HandShakeConfirmed> >(shared_from_this(), (bithorde::HandShakeConfirmed&) msg));
		default: break;
		}
	}
	if (auto msgType = bithorde::Stream::descriptor()->FindFieldByNumber(type)) {
		cerr << "ERROR: BitHorde State Error (" << _state << "," << msgType->name() << "), Disconnecting" << endl;
	} else {
		cerr << "ERROR: BitHorde Unknown Message Error (" << _state << "," << type << "), Disconnecting" << endl;
	}
	close();
}

void Client::onMessage( const std::shared_ptr< MessageContext< HandShake > >& msgCtx )
{
	const auto& msg = msgCtx->message();
	BOOST_ASSERT(_state & SaidHello);
	if (msg.protoversion() >= 2) {
		_protoVersion = 2;
	} else {
		cerr << "Only Protocol-version 2 or higher supported" << endl;
		return close();
	}

	if (_peerName.empty()) {
		_peerName = msg.name();
		_connection->setLogTag(_peerName);
	} else if (_peerName != msg.name()) {
		cerr << "Error: Expected " << _peerName << " but was greeted by " << msg.name() << endl;
		return close();
	}

	if (msg.has_challenge()) {
		if (_key.empty()) {
			cerr << "Challenged from " << msg.name() << " without known key." << endl;
			return close();
		} else {
			auto cipher = (byte)(_sendCipher ? _sendCipher->type : bithorde::CLEARTEXT);
			string cipheriv(_sendCipher ? _sendCipher->iv : "");
			CryptoPP::HMAC<CryptoPP::SHA256> digest((const byte*)_key.data(), _key.size());
			digest.Update((const byte*)msg.challenge().data(), msg.challenge().size());
			digest.Update(&cipher, sizeof(cipher));
			digest.Update((const byte*)cipheriv.data(), cipheriv.size());

			auto digest_ = (byte*)alloca(digest.DigestSize());
			digest.Final(digest_);

			HandShakeConfirmed auth;
			if (_sendCipher) {
				auth.set_cipher((bithorde::CipherType)_sendCipher->type);
				auth.set_cipheriv(_sendCipher->iv);
			}
			auth.set_authentication(digest_, digest.DigestSize());
			sendMessage(Connection::MessageType::HandShakeConfirmed, auth);
			addStateFlag(SentAuth);
		}
	} else {
		addStateFlag(SentAuth);
	}
	if (_sentChallenge.empty())
		addStateFlag(GotAuth);
}

void Client::addStateFlag(Client::State s)
{
	_state = (State)(_state | s);
	if (_state == Authenticated)
		setAuthenticated(_peerName);
}

void Client::setAuthenticated(const std::string peerName)
{
	if (peerName.size()) {
		if (_sendCipher)
			_connection->setEncryption(_sendCipher->type, _key, _sendCipher->iv);
		if (_recvCipher)
			_connection->setDecryption(_recvCipher->type, _key, _recvCipher->iv);
		for (auto iter = _assetMap.begin(); iter != _assetMap.end(); iter++) {
			auto binding = iter->second;
			BOOST_ASSERT(binding && binding->readAsset());
			binding->setTimer(DEFAULT_ASSET_TIMEOUT);
			informBound(*iter->second, DEFAULT_ASSET_TIMEOUT.total_milliseconds());
		}
		_connection->setKeepalive(new Keepalive(*this));
	}
	authenticated(*this, peerName);
}

void Client::onMessage( const std::shared_ptr< MessageContext< BindRead > >& msgCtx ) {
	cerr << "unsupported: handling BindRead" << endl;
	bithorde::AssetStatus resp;
	resp.set_handle( msgCtx->message().has_handle());
	resp.set_status(ERROR);
	sendMessage(Connection::MessageType::AssetStatus, resp);
}

void Client::onMessage( const std::shared_ptr< MessageContext< AssetStatus > >& msgCtx ) {
	const auto& msg = msgCtx->message();
	if (!msg.has_handle())
		return;
	Asset::Handle handle = msg.handle();
	if (_assetMap.count(handle)) {
		AssetBinding& a = *_assetMap[handle];
		a.clearTimer();
		if (a && a->status != bithorde::Status::INVALID_HANDLE) {
			if (a->status == bithorde::Status::NONE)
				assetResponseTime.post((ptime::microsec_clock::universal_time() - a._opened_at).total_milliseconds());
			a->handleMessage( msg );
		} else if ( msg.status() != bithorde::Status::SUCCESS) {
			_assetMap.erase(handle);
			_handleAllocator.free(handle);
		}
	} else if ( msg.ids_size()) {
		cerr << "WARNING: " << peerName() << ':' << handle << " AssetStatus " << bithorde::Status_Name( msg.status()) << " for unmapped handle" << endl;
	}
}

void Client::onMessage( const std::shared_ptr< MessageContext< Read::Request > >& msgCtx ) {
	cerr << "unsupported: handling Read-Requests" << endl;
	bithorde::Read::Response resp;
	resp.set_reqid( msgCtx->message().reqid() );
	resp.set_status(ERROR);
	sendMessage(Connection::MessageType::ReadResponse, resp);
}

void Client::onMessage( const std::shared_ptr< MessageContext< Read::Response > >& msgCtx ) {
	const auto& msg = msgCtx->message();
	if (_requestIdMap.count(msg.reqid())) {
		Asset::Handle assetHandle = _requestIdMap[msg.reqid()];
		releaseRPCRequest( msg.reqid());
		if (_assetMap.count(assetHandle)) {
			Asset* a = _assetMap[assetHandle]->asset();
			if (a) {
				a->handleMessage( msgCtx );
			} else {
				cerr << "WARNING " << peerName() << ": ReadResponse " << msg.reqid() << " for handle being closed " << assetHandle << endl;
			}
		} else {
			cerr << "WARNING " << peerName() << ": ReadResponse " << msg.reqid() << " for unmapped handle " << assetHandle << endl;
		}
	} else {
		cerr << "WARNING " << peerName() << ": ReadResponse with unknown requestId" << endl;
	}
}

void Client::onMessage( const std::shared_ptr< MessageContext< BindWrite > >& msgCtx ) {
	cerr << "unsupported: handling BindWrite" << endl;
	bithorde::AssetStatus resp;
	resp.set_handle(msgCtx->message().handle());
	resp.set_status(ERROR);
	sendMessage(Connection::MessageType::AssetStatus, resp);
}
void Client::onMessage( const std::shared_ptr< MessageContext< DataSegment > >& msgCtx ) {
	cerr << "unsupported: handling DataSegment-pushes" << endl;
	close();
}
void Client::onMessage( const std::shared_ptr< MessageContext< HandShakeConfirmed > >& msgCtx ) {
	const auto& msg = msgCtx->message();
	CryptoPP::HMAC<CryptoPP::SHA256> digest((const byte*)_key.data(), _key.size());
	digest.Update((const byte*)_sentChallenge.data(), _sentChallenge.size());
	auto cipher = (byte)msg.cipher();
	digest.Update(&cipher, sizeof(cipher));
	digest.Update((const byte*)msg.cipheriv().data(), msg.cipheriv().size());
	if ((msg.authentication().size() == digest.DigestSize())
	    && digest.Verify((const byte*)msg.authentication().data())) {
		if (msg.has_cipher() && msg.cipher() != bithorde::CLEARTEXT)
			_recvCipher.reset(new CipherConfig(msg.cipher(), msg.cipheriv()));
		addStateFlag(GotAuth);
	} else {
		setAuthenticated("");
	}
}
void Client::onMessage( const std::shared_ptr< MessageContext< Ping > >& msgCtx ) {
	if (msgCtx->message().timeout()) {
		bithorde::Ping reply;
		auto deadline =  std::chrono::steady_clock::now() + std::chrono::milliseconds(msgCtx->message().timeout());
		sendMessage(Connection::MessageType::Ping, reply, deadline, false);
	}
}

bool Client::bind(ReadAsset &asset) {
	return bind(asset, DEFAULT_ASSET_TIMEOUT.total_milliseconds());
}

bool Client::bind(ReadAsset& asset, int timeout_ms)
{
	RouteTrace requesters;
	(*requesters.Add()) = rand64();
	return bind(asset, timeout_ms, requesters);
}

bool Client::bind(ReadAsset& asset, const RouteTrace& requesters)
{
	return bind(asset, DEFAULT_ASSET_TIMEOUT.total_milliseconds(), requesters);
}

bool Client::bind(ReadAsset& asset, int timeout_ms, const RouteTrace& requesters)
{
	if (!asset.isBound()) {
		BOOST_ASSERT(asset._handle < 0);
		BOOST_ASSERT(asset.requestIds().size() > 0);
		auto handle = _handleAllocator.allocate();
		if (handle >= MAX_ASSETS)
			return false;
		asset._handle = handle;
		BOOST_ASSERT(asset._handle > 0);
		BOOST_ASSERT(_assetMap.count(asset._handle) == 0);
		auto& bind = _assetMap[asset._handle];
		bind = std::make_shared<AssetBinding>(this, &asset, asset._handle);
		bind->setTimer(boost::posix_time::millisec(timeout_ms));
	}
	 _assetMap[asset._handle]->requesters().CopyFrom(requesters);

	return informBound(*_assetMap[asset._handle], timeout_ms);
}

bool Client::bind(UploadAsset & asset, int timeout_ms)
{
	BOOST_ASSERT(asset._client.get() == this);
	BOOST_ASSERT(asset._handle < 0);
	BOOST_ASSERT(asset.size() > 0);
	auto handle = _handleAllocator.allocate();
	if (handle >= MAX_ASSETS)
		return false;
	if (!timeout_ms)
		timeout_ms = UPLOAD_ASSET_TIMEOUT.total_milliseconds();
	asset._handle = handle;
	auto& bind = _assetMap[asset._handle];
	bind = std::make_shared<AssetBinding>(this, &asset, asset._handle);
	bind->setTimer(boost::posix_time::milliseconds(timeout_ms));
	bithorde::BindWrite msg;
	msg.set_handle(asset._handle);
	msg.set_size(asset.size());
	const auto& link = asset.link();
	if (!link.empty())
		msg.set_linkpath(link.string());
	return sendMessage(Connection::MessageType::BindWrite, msg, Message::NEVER, false);
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
		return informBound(binding, DEFAULT_ASSET_TIMEOUT.total_milliseconds());
	else
		return true; // Since connection is down, other side should not have the bound state as it is.
}

bool Client::informBound(const AssetBinding& asset, int timeout_ms)
{
	BOOST_ASSERT(asset._handle >= 0);

	if (!_connection)
		return false;

	bithorde::BindRead msg;
	msg.set_handle(asset._handle);

	msg.set_timeout(timeout_ms);
	msg.mutable_requesters()->MergeFrom(asset.requesters());

	if (auto readAsset = asset.readAsset()) {
		msg.mutable_ids()->CopyFrom(readAsset->requestIds());
		return sendMessage(Connection::MessageType::BindRead, msg, Message::in(timeout_ms), false);
	} else {
		return sendMessage(Connection::MessageType::BindRead, msg, Message::NEVER, true);
	}
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
