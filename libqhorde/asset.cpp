#include "asset.h"
#include "client.h"

Asset::Asset(Client * client, QObject * parent) :
    QObject(parent),
    _client(client),
    _handle(-1),
    _size(-1)
{}

bool Asset::isBound()
{
    return _handle >= 0;
}

void Asset::close()
{
    Q_ASSERT(_client && isBound());
    _client->release(*this);
}

quint64 Asset::size()
{
    return _size;
}

void Asset::handleMessage(const bithorde::AssetStatus & msg)
{
    emit statusUpdate(msg);
}

ReadAsset::ReadAsset(Client * client, IdList requestIds, QObject * parent) :
    Asset(client, parent),
    _requestIds(requestIds)
{}

ReadAsset::IdList & ReadAsset::requestIds()
{
    return _requestIds;
}

void ReadAsset::handleMessage(const bithorde::AssetStatus &msg)
{
    if (msg.has_size()) {
        Q_ASSERT(_size < 0);
        _size = msg.size();
    }
    Asset::handleMessage(msg);
}

void ReadAsset::handleMessage(const bithorde::Read::Response &msg) {
    if (msg.status() == bithorde::SUCCESS) {
        const std::string & content = msg.content();
        QByteArray payload(content.data(), content.length());
        emit dataArrived(msg.offset(), payload, msg.reqid());
    } else {
        // TODO
    }
    _client->releaseRPCRequest(msg.reqid());
}

int ReadAsset::aSyncRead(quint64 offset, ssize_t size)
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

UploadAsset::UploadAsset(Client * client, QObject * parent) :
    Asset(client, parent)
{}

void UploadAsset::setSize(quint64 size)
{
    Q_ASSERT(!isBound());
    _size = size;
}

bool UploadAsset::tryWrite(quint64 offset, QByteArray data)
{
    Q_ASSERT(isBound());
    bithorde::DataSegment msg;
    msg.set_handle(_handle);
    msg.set_offset(offset);
    msg.set_content(data.data(), data.length());
    return _client->sendMessage(Connection::DataSegment, msg);
}

void UploadAsset::handleMessage(const bithorde::Read::Response&) {
    Q_ASSERT(false);
}
