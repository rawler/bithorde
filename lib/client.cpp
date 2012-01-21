#include "client.h"

#include <iostream>
#include <stdlib.h>
#include <string.h>

#include <Poco/Delegate.h>

#define DEFAULT_ASSET_TIMEOUT 4000

using namespace std;
using namespace Poco;

uint64_t rand64() {
	// TODO: improve seeding throuh srandomdev
	return (((uint64_t)rand()) << 32) | rand();
}

Client::Client(Connection & connection, std::string myName) :
	_connection(&connection),
	_myName(myName),
	_handleAllocator(1),
	_rpcIdAllocator(1),
	_protoVersion(0)
{
	_connection->message += delegate(this, &Client::onIncomingMessage);
	_connection->writable += delegate(this, &Client::onWritable);

	sayHello();
}

Client::~Client() {
	_connection->message += delegate(this, &Client::onIncomingMessage);
	_connection->writable += delegate(this, &Client::onWritable);
}

bool Client::sendMessage(Connection::MessageType type, const::google::protobuf::Message &msg)
{
	poco_assert(_connection);
	return _connection->sendMessage(type, msg);
}

void Client::sayHello() {
	bithorde::HandShake h;
	h.set_protoversion(2);
	h.set_name(_myName);

	sendMessage(Connection::HandShake, h);
}

void Client::onWritable (Poco::EventArgs&) {
	writable.notify(this, NO_ARGS);
}

void Client::onIncomingMessage(Connection::Message &msg)
{
	switch (msg.type) {
	case Connection::HandShake: return onMessage((bithorde::HandShake&) msg.content);
	case Connection::BindRead: return onMessage((bithorde::BindRead&) msg.content);
	case Connection::AssetStatus: return onMessage((bithorde::AssetStatus&) msg.content);
	case Connection::ReadRequest: return onMessage((bithorde::Read::Request&) msg.content);
	case Connection::ReadResponse: return onMessage((bithorde::Read::Response&) msg.content);
	case Connection::BindWrite: return onMessage((bithorde::BindWrite&) msg.content);
	case Connection::DataSegment: return onMessage((bithorde::DataSegment&) msg.content);
	case Connection::HandShakeConfirmed: return onMessage((bithorde::HandShakeConfirmed&) msg.content);
	case Connection::Ping: return onMessage((bithorde::Ping&) msg.content);
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
		authenticated.notify(this, _peerName);
	}
}

void Client::onMessage(const bithorde::BindRead & msg) {}
void Client::onMessage(const bithorde::AssetStatus & msg) {
	if (!msg.has_handle())
		return;
	Asset::Handle handle = msg.handle();
	if (_assetMap.count(handle)) {
		Asset* a = _assetMap[handle];
		a->handleMessage(msg);
	} else {
		cerr << "WARNING: AssetStatus for unmapped handle" << endl;
		// TODO: Log error
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
	_connection->sendMessage(Connection::Ping, reply);
}

bool Client::bind(ReadAsset &asset) {
	poco_assert(asset._client == this);
	poco_assert(asset._handle < 0);
	poco_assert(asset.requestIds().size() > 0);
	asset._handle = _handleAllocator.allocate();
	_assetMap[asset._handle] = &asset;
	bithorde::BindRead msg;
	msg.set_handle(asset._handle);

	ReadAsset::IdList& ids = asset.requestIds();
	for (ReadAsset::IdList::iterator iter = ids.begin(); iter < ids.end(); iter++) {
		ReadAsset::Identifier& id = *iter;
		bithorde::Identifier * bhId = msg.add_ids();
		bhId->set_type(id.first);
		bhId->set_id(id.second.data(), id.second.size());
	}
	msg.set_timeout(DEFAULT_ASSET_TIMEOUT);
	msg.set_uuid(rand64());
	return _connection->sendMessage(Connection::BindRead, msg);
}

bool Client::bind(UploadAsset & asset)
{
	poco_assert(asset._client == this);
	poco_assert(asset._handle < 0);
	poco_assert(asset.size() > 0);
	asset._handle = _handleAllocator.allocate();
	_assetMap[asset._handle] = &asset;
	bithorde::BindWrite msg;
	msg.set_handle(asset._handle);
	msg.set_size(asset.size());
	return _connection->sendMessage(Connection::BindWrite, msg);
}

bool Client::release(Asset & asset)
{
	poco_assert(asset.isBound());
	bithorde::BindRead msg;
	msg.set_handle(asset._handle);
	msg.set_timeout(DEFAULT_ASSET_TIMEOUT);
	msg.set_uuid(rand64());

	_assetMap.erase(asset._handle);
	_handleAllocator.free(asset._handle);
	asset._handle = -1;

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
