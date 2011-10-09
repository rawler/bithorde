#include <stdlib.h>
#include <string.h>

#include "client.h"

#include <QtCore/QTextStream>

Client::Client(Connection & connection, QString myName, QObject *parent) :
    QObject(parent),
    _connection(&connection),
    _myName(myName),
    _handleAllocator(1),
    _protoVersion(0)
{
    connect(_connection, SIGNAL(connected()), SLOT(onConnected()));
    connect(_connection, SIGNAL(message(Connection::MessageType,const::google::protobuf::Message&)), SLOT(onMessage(Connection::MessageType, const::google::protobuf::Message&)));
    connect(_connection, SIGNAL(sent()), SIGNAL(sent()));
    if (connection.isConnected())
        onConnected();
}

bool Client::sendMessage(Connection::MessageType type, const::google::protobuf::Message &msg)
{
    Q_ASSERT(_connection && _connection->isConnected());
    return _connection->sendMessage(type, msg);
}

void Client::onConnected() {
    bithorde::HandShake h;
    h.set_protoversion(2);
    QByteArray nameBytes =_myName.toUtf8();
    h.set_name(nameBytes.data(), nameBytes.length());

    sendMessage(Connection::HandShake, h);
}

void Client::onMessage(Connection::MessageType type, const ::google::protobuf::Message & _msg)
{
    switch (type) {
    case Connection::HandShake: return onMessage((bithorde::HandShake&) _msg);
    case Connection::BindRead: return onMessage((bithorde::BindRead&) _msg);
    case Connection::AssetStatus: return onMessage((bithorde::AssetStatus&) _msg);
    case Connection::ReadRequest: return onMessage((bithorde::Read::Request&) _msg);
    case Connection::ReadResponse: return onMessage((bithorde::Read::Response&) _msg);
    case Connection::BindWrite: return onMessage((bithorde::BindWrite&) _msg);
    case Connection::DataSegment: return onMessage((bithorde::DataSegment&) _msg);
    case Connection::HandShakeConfirmed: return onMessage((bithorde::HandShakeConfirmed&) _msg);
    case Connection::Ping: return onMessage((bithorde::Ping&) _msg);
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

    _peerName = QString::fromStdString(msg.name());

    if (msg.has_challenge()) {
        // Setup encryption
    } else {
        authenticated(_peerName);
    }
}

void Client::onMessage(const bithorde::BindRead & msg) {}
void Client::onMessage(const bithorde::AssetStatus & msg) {
    if (!msg.has_handle())
        return;
    Asset::Handle handle = msg.handle();
    if (_assetMap.contains(handle)) {
        Asset* a = _assetMap[handle];
        a->handleMessage(msg);
    } else {
        QTextStream(stderr) << "WARNING: AssetStatus for unmapped handle\n";
        // TODO: Log error
    }
}
void Client::onMessage(const bithorde::Read::Request & msg) {}
void Client::onMessage(const bithorde::Read::Response & msg) {}
void Client::onMessage(const bithorde::BindWrite & msg) {}
void Client::onMessage(const bithorde::DataSegment & msg) {}
void Client::onMessage(const bithorde::HandShakeConfirmed & msg) {}
void Client::onMessage(const bithorde::Ping & msg) {}

void Client::bindWrite(UploadAsset & asset)
{
    Q_ASSERT(asset._client == this);
    Q_ASSERT(asset.size() > 0);
    asset._handle = _handleAllocator.allocate();
    _assetMap[asset._handle] = &asset;
    bithorde::BindWrite msg;
    msg.set_handle(asset._handle);
    msg.set_size(asset.size());
    _connection->sendMessage(Connection::BindWrite, msg);
}

void Client::release(Asset & asset)
{
    Q_ASSERT(asset.isBound());
    bithorde::BindRead msg;
    msg.set_handle(asset._handle);
    msg.set_timeout(4000);
    msg.set_uuid(12736871236);

    _assetMap.remove(asset._handle);
    _handleAllocator.free(asset._handle);
}






