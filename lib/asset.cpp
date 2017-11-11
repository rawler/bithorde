
#include "asset.h"

#include <boost/asio/placeholders.hpp>
#include <boost/filesystem.hpp>
#include <iostream>

#include "buffer.hpp"
#include "client.h"

using namespace std;
namespace fs = boost::filesystem;
namespace ptime = boost::posix_time;

using namespace bithorde;

bool bithorde::idsOverlap(const bithorde::Ids& a, const bithorde::Ids& b) {
	for (auto aiter=a.begin(); aiter != a.end(); aiter++) {
		for (auto biter=b.begin(); biter != b.end(); biter++) {
			if ((aiter->id() == biter->id()) && (aiter->type() == biter->type()))
				return true;
		}
	}
	return false;
}

Asset::Asset(const bithorde::Asset::ClientPointer& client) :
	status(Status::NONE),
	_client(client),
	_ioSvc(client->_ioSvc),
	_handle(-1),
	_size(-1)
{}

Asset::~Asset() {
	if (isBound())
		close();
}

const Asset::ClientPointer& Asset::client()
{
	return _client;
}

boost::asio::io_service& Asset::ioSvc()
{
	return _ioSvc;
}

bool Asset::isBound()
{
	return _handle >= 0;
}

Asset::Handle Asset::handle()
{
	return _handle;
}

string Asset::label()
{
	ostringstream buf;
	if (_client)
		buf << _client->_peerName;
	buf << ':' << _handle;
	return buf.str();
}

void Asset::close()
{
	BOOST_ASSERT(_client && isBound());
	_client->release(*this);
	_handle = -1;
}

uint64_t Asset::size()
{
	return _size;
}

const unordered_set< uint64_t >& Asset::servers()
{
	return _servers;
}

void Asset::handleMessage(const bithorde::AssetStatus & msg)
{
	status = msg.status();
	_servers.clear();
	_servers.insert(msg.servers().begin(), msg.servers().end());
	statusUpdate(msg);
}

ReadRequestContext::ReadRequestContext(ReadAsset* asset, uint64_t offset, size_t size, int32_t timeout) :
	_asset(asset),
	_client(asset->client()),
	_timer(asset->ioSvc()),
	_requested_at(ptime::microsec_clock::universal_time())
{
	set_handle(asset->handle());
	set_reqid(_client->allocRPCRequest(handle()));
	set_offset(offset);
	set_size(size);
	set_timeout(timeout); // Assume 100ms latency on each link.
}
ReadRequestContext::~ReadRequestContext() {
	if (_asset)
		_client->releaseRPCRequest(reqid());
}

void ReadRequestContext::armTimer(int32_t timeout)
{
	auto self = shared_from_this();
	_timer.expires_from_now(boost::posix_time::millisec(timeout));
	_timer.async_wait([=](const boost::system::error_code& ec){
		self->timer_callback(ec);
	});
}

void ReadRequestContext::cancel()
{
	if (_asset) {
		auto asset = _asset;
		_asset = NULL;
		asset->dataArrived(offset(), NullBuffer::instance, reqid());
	}
	_timer.cancel();
}

void ReadRequestContext::callback(const std::shared_ptr< MessageContext<Read::Response> >& msgCtx)
{
	const auto& msg = msgCtx->message();
	if (!_asset) // Cancelled
		return;
	auto asset = _asset;
	_asset = NULL; // Handle circular triggers
	asset->readResponseTime.post((ptime::microsec_clock::universal_time() - _requested_at).total_milliseconds());
	if (msg.status() == bithorde::SUCCESS) {
		asset->dataArrived(msg.offset(), std::make_shared<ReadResponseCtxBuffer>(msgCtx), msg.reqid());
	} else {
		cerr << "Error: failed read, " << bithorde::Status_Name(msg.status()) << endl;
		asset->dataArrived(msg.offset(), NullBuffer::instance, msg.reqid());
	}
}

void ReadRequestContext::timer_callback(const boost::system::error_code& error)
{
	if (!error) {
		// Timeout occurred
		if (_asset) {
			auto asset = _asset;
			_asset = NULL;
			asset->readResponseTime.post((ptime::microsec_clock::universal_time() - _requested_at).total_milliseconds());
			asset->dataArrived(offset(), NullBuffer::instance, reqid());
			asset->clearOffset(offset(), reqid());
		}
	}
}

ReadAsset::ReadAsset(const bithorde::ReadAsset::ClientPointer& client, const bithorde::Ids& requestIds) :
	Asset(client),
	readResponseTime(0.95, "ms"),
	_requestIds(requestIds)
{}

ReadAsset::~ReadAsset()
{
	cancelRequests();
}

void ReadAsset::cancelRequests() {
	for (auto iter = _requestMap.begin(); iter != _requestMap.end(); iter++) {
		iter->second->cancel();
	}
	_requestMap.clear();
}

const bithorde::Ids& ReadAsset::requestIds() const
{
	return _requestIds;
}

const bithorde::Ids& ReadAsset::confirmedIds() const
{
	return _confirmedIds;
}

void ReadAsset::handleMessage(const bithorde::AssetStatus &msg)
{
	if (msg.has_size()) {
		if (_size < 0) {
			_size = msg.size();
		} else if (_size != (int64_t)msg.size()) {
			// TODO: Application::instance().logger().warning("Peer tried to change asset-size.");
		}
	}
	Asset::handleMessage(msg);
}

void ReadAsset::handleMessage( const std::shared_ptr< MessageContext< Read::Response > >& msgCtx ) {
	const auto& msg = msgCtx->message();
	auto it = _requestMap.lower_bound(msg.offset());
	auto end = _requestMap.upper_bound(msg.offset());
	while (it != end) {
		auto next = it;
		next++;
		auto ctx = it->second;
		_requestMap.erase(it);
		ctx->callback(msgCtx);
		it = next;
	}
}

void ReadAsset::clearOffset(ReadAsset::off_t offset, uint32_t reqid)
{
	auto it = _requestMap.lower_bound(offset);
	auto end = _requestMap.upper_bound(offset);
	while (it != end) {
		auto next = it;
		next++;
		if (it->second->reqid() == reqid)
			_requestMap.erase(it);
		it = next;
	}
}

int ReadAsset::aSyncRead(ReadAsset::off_t offset, ssize_t size, int32_t timeout)
{
	if (!_client || !_client->isConnected())
		return -1;
	auto _timeout = timeout - 100; // Assume 100ms latency on each link
	if (_timeout <= 0)
		return -1;
	int64_t maxSize = _size - offset;
	if (size > maxSize)
		size = maxSize;
	auto req = std::make_shared<ReadRequestContext>(this, offset, size, _timeout);
	if (_client->sendMessage(Connection::ReadRequest, *req)) {
		req->armTimer(timeout);
		_requestMap.emplace(offset, req);
	} else {
		req->cancel();
	}
	return req->reqid();
}

UploadAsset::UploadAsset(const bithorde::Asset::ClientPointer& client, uint64_t size)
	: Asset(client)
{
	_size = size;
}

UploadAsset::UploadAsset(const bithorde::Asset::ClientPointer& client, const boost::filesystem::path& path)
	: Asset(client), _linkPath(fs::absolute(path))
{
	_size = fs::file_size(_linkPath);
}

bool UploadAsset::tryWrite(uint64_t offset, byte* data, size_t amount)
{
	BOOST_ASSERT(isBound());
	bithorde::DataSegment msg;
	msg.set_handle(_handle);
	msg.set_offset(offset);
	msg.set_content(data, amount);
	return _client->sendMessage(Connection::DataSegment, msg);
}

const fs::path& UploadAsset::link()
{
	return _linkPath;
}


void UploadAsset::handleMessage(const std::shared_ptr< MessageContext< Read::Response > >& msgCtx) {
	BOOST_ASSERT(false);
}
