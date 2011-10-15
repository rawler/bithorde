#ifndef CLIENT_H
#define CLIENT_H

#include <QtCore/QMap>
#include <QtCore/QObject>
#include <QtCore/QString>

#include "asset.h"
#include "connection.h"
#include "allocator.h"

class Client : public QObject
{
    Q_OBJECT

    Connection * _connection;

    QString _myName;
    QString _peerName;

    QMap<Asset::Handle, Asset*> _assetMap;
    QMap<int, Asset::Handle> _requestIdMap;
    CachedAllocator<Asset::Handle> _handleAllocator;
    CachedAllocator<int> _rpcIdAllocator;

    quint8 _protoVersion;
public:
    explicit Client(Connection & conn, QString myName, QObject *parent = 0);

    void bindRead(ReadAsset & asset);
    void bindWrite(UploadAsset & asset);

    bool sendMessage(Connection::MessageType type, const ::google::protobuf::Message & msg);
signals:
    void authenticated(QString remote);
    void sent();

private slots:
    void onConnected();
    void onMessage(Connection::MessageType type, const ::google::protobuf::Message & msg);

protected:
    void onMessage(const bithorde::HandShake & msg);
    void onMessage(const bithorde::BindRead & msg);
    void onMessage(const bithorde::AssetStatus & msg);
    void onMessage(const bithorde::Read::Request & msg);
    void onMessage(const bithorde::Read::Response & msg);
    void onMessage(const bithorde::BindWrite & msg);
    void onMessage(const bithorde::DataSegment & msg);
    void onMessage(const bithorde::HandShakeConfirmed & msg);
    void onMessage(const bithorde::Ping & msg);

private:
    friend class Asset;
    friend class ReadAsset;
    void release(Asset & a);

    int allocRPCRequest(Asset::Handle asset);
    void releaseRPCRequest(int reqId);
};

#endif // CLIENT_H
