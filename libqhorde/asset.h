#ifndef ASSET_H
#define ASSET_H

#include <QtCore/QObject>
#include <QtCore/QPair>

#include "proto/bithorde.pb.h"

class Client;

class Asset : public QObject
{
    Q_OBJECT
public:
    typedef int Handle;
    explicit Asset(Client * client, QObject * parent);
    virtual ~Asset();

    bool isBound();
    quint64 size();
signals:
    void closed();
    void statusUpdate(const bithorde::AssetStatus & msg);

public slots:
    void close();

protected:
    Client * _client;
    Handle _handle;
    qint64 _size;

    friend class Client;
    virtual void handleMessage(const bithorde::AssetStatus &msg);
    virtual void handleMessage(const bithorde::Read::Response &msg) = 0;
};

class ReadAsset : public Asset
{
    Q_OBJECT
public:
    typedef QPair<bithorde::HashType, QByteArray> Identifier;
    typedef QList<Identifier> IdList;

    explicit ReadAsset(Client * client, IdList requestIds, QObject * parent=0);

    int aSyncRead(quint64 offset, ssize_t size);
    IdList & requestIds();

signals:
    void dataArrived(quint64 offset, QByteArray data, int tag);

protected:
    virtual void handleMessage(const bithorde::AssetStatus &msg);
    virtual void handleMessage(const bithorde::Read::Response &msg);

private:
    IdList _requestIds;
};

class UploadAsset : public Asset
{
    Q_OBJECT
public:
    explicit UploadAsset(Client * client, QObject * parent=0);
    void setSize(quint64 size);

public slots:
    bool tryWrite(quint64 offset, QByteArray data);

protected:
    virtual void handleMessage(const bithorde::Read::Response &msg);
};

#endif // ASSET_H
