
#include "asset.h"

#include <boost/filesystem.hpp>
#include <iostream>

#include "client.h"

using namespace std;
namespace fs = boost::filesystem;

using namespace bithorde;

Asset::Asset(const bithorde::Asset::ClientPointer& client) :
	status(Status::NONE),
	_client(client),
	_handle(-1),
	_size(-1)
{}

Asset::~Asset() {
	if (isBound())
		close();
}

bool Asset::isBound()
{
	return _handle >= 0;
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

void Asset::handleMessage(const bithorde::AssetStatus & msg)
{
	status = msg.status();
	statusUpdate(msg);
}

ReadAsset::ReadAsset(const bithorde::ReadAsset::ClientPointer& client, const BitHordeIds& requestIds) :
	Asset(client),
	_requestIds(requestIds)
{}

const BitHordeIds& ReadAsset::requestIds() const
{
	return _requestIds;
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

void ReadAsset::handleMessage(const bithorde::Read::Response &msg) {
	if (msg.status() == bithorde::SUCCESS) {
		dataArrived(msg.offset(), msg.content(), msg.reqid());
	} else {
		cerr << "Error: failed read, " << msg.status() << endl;
		string nil;
		dataArrived(msg.offset(), nil, msg.reqid());
	}
	_client->releaseRPCRequest(msg.reqid());
}

int ReadAsset::aSyncRead(uint64_t offset, ssize_t size)
{
	if (!_client || !_client->isConnected())
		return -1;
	int reqId = _client->allocRPCRequest(_handle);
	int64_t maxSize = _size - offset;
	if (size > maxSize)
		size = maxSize;
	bithorde::Read_Request req;
	req.set_handle(_handle);
	req.set_reqid(reqId);
	req.set_offset(offset);
	req.set_size(size);
	req.set_timeout(4000);
	_client->sendMessage(Connection::ReadRequest, req);
	return reqId;
}

UploadAsset::UploadAsset(const bithorde::Asset::ClientPointer& client, uint64_t size)
	: Asset(client)
{
	_size = size;
}

UploadAsset::UploadAsset(const bithorde::Asset::ClientPointer& client, const boost::filesystem3::path& path)
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

void UploadAsset::handleMessage(const bithorde::Read::Response&) {
	BOOST_ASSERT(false);
}
