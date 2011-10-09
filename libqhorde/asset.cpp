#include "asset.h"
#include "client.h"

Asset::Asset(Client * client, QObject * parent) :
    QObject(parent),
    _client(client),
    _handle(-1)
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

ReadAsset::ReadAsset(Client * client, QObject * parent) :
    Asset(client, parent)
{}

void ReadAsset::aSyncRead(quint64 offset, ssize_t size)
{
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

