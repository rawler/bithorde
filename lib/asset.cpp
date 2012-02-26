#include "asset.h"
#include "client.h"

#include <iostream>

using namespace std;

Asset::Asset(ClientPointer client) :
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
	statusUpdate(msg);;
}

ReadAsset::ReadAsset(ClientPointer client, IdList requestIds) :
	Asset(client),
	_requestIds(requestIds)
{}

ReadAsset::IdList & ReadAsset::requestIds()
{
	return _requestIds;
}

void ReadAsset::handleMessage(const bithorde::AssetStatus &msg)
{
	if (msg.has_size()) {
		if (_size < 0) {
			_size = msg.size();
		} else if (_size != msg.size()) {
			// TODO: Application::instance().logger().warning("Peer tried to change asset-size.");
		}
	}
	Asset::handleMessage(msg);
}

void ReadAsset::handleMessage(const bithorde::Read::Response &msg) {
	if (msg.status() == bithorde::SUCCESS) {
		const std::string & content = msg.content();
		ByteArray data(content.begin(), content.end());
		dataArrived(msg.offset(), data, msg.reqid());
	} else {
                cerr << "Error: failed read, " << msg.status() << endl;
                ByteArray nil;
		dataArrived(msg.offset(), nil, msg.reqid());
	}
	_client->releaseRPCRequest(msg.reqid());
}

int ReadAsset::aSyncRead(uint64_t offset, ssize_t size)
{
	if (!_client)
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

UploadAsset::UploadAsset(ClientPointer client, uint64_t size) :
	Asset(client)
{
	_size = size;
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

void UploadAsset::handleMessage(const bithorde::Read::Response&) {
	BOOST_ASSERT(false);
}
