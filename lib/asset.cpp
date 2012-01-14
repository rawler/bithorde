#include "asset.h"
#include "client.h"

#include <Poco/Debugger.h>
#include <Poco/Util/Application.h>

using namespace std;
using namespace Poco;
using namespace Poco::Util;

Asset::Asset(Client * client) :
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
	poco_assert(_client && isBound());
	_client->release(*this);
	_handle = -1;
}

uint64_t Asset::size()
{
	return _size;
}

void Asset::handleMessage(const bithorde::AssetStatus & msg)
{
	statusUpdate.notify(this, msg);;
}

ReadAsset::ReadAsset(Client * client, IdList requestIds) :
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
			Application::instance().logger().warning("Peer tried to change asset-size.");
		}
	}
	Asset::handleMessage(msg);
}

void ReadAsset::handleMessage(const bithorde::Read::Response &msg) {
	if (msg.status() == bithorde::SUCCESS) {
		const std::string & content = msg.content();
		Segment s(msg.offset(), ByteArray(content.begin(), content.end()), msg.reqid());
		dataArrived.notify(this, s);
	} else {
		// TODO
	}
	_client->releaseRPCRequest(msg.reqid());
}

int ReadAsset::aSyncRead(uint64_t offset, ssize_t size)
{
	if (!_client)
		return -1;
	int reqId = _client->allocRPCRequest(_handle);
	bithorde::Read_Request req;
	req.set_handle(_handle);
	req.set_reqid(reqId);
	req.set_offset(offset);
	req.set_size(size);
	req.set_timeout(4000);
	_client->sendMessage(Connection::ReadRequest, req);
	return reqId;
}

UploadAsset::UploadAsset(Client * client) :
	Asset(client)
{}

void UploadAsset::setSize(uint64_t size)
{
	poco_assert(!isBound());
	_size = size;
}

bool UploadAsset::tryWrite(uint64_t offset, ByteArray data)
{
	poco_assert(isBound());
	bithorde::DataSegment msg;
	msg.set_handle(_handle);
	msg.set_offset(offset);
	msg.set_content(data.data(), data.size());
	return _client->sendMessage(Connection::DataSegment, msg);
}

void UploadAsset::handleMessage(const bithorde::Read::Response&) {
	poco_assert(false);
}
