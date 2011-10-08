#include "asset.h"
#include "client.h"

Asset::Asset(Client *parent) :
    QObject(parent),
    _client(parent),
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

ReadAsset::ReadAsset(Client *parent) :
    Asset(parent)
{}

UploadAsset::UploadAsset(Client *parent) :
    Asset(parent)
{}

void UploadAsset::setSize(quint64 size)
{
    Q_ASSERT(!isBound());
    _size = size;
}

