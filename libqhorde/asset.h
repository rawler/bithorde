#ifndef ASSET_H
#define ASSET_H

#include <QObject>
#include "proto/bithorde.pb.h"

class Client;

class Asset : public QObject
{
    Q_OBJECT
public:
    typedef int Handle;
protected:
    Client * _client;
    Handle _handle;
    quint64 _size;
public:
    explicit Asset(Client * client, QObject * parent);

    bool isBound();
    quint64 size();
signals:
    void closed();
    void statusUpdate(const bithorde::AssetStatus & msg);

public slots:
    void close();

private:
    friend class Client;
    void handleMessage(const bithorde::AssetStatus &msg);
};

class ReadAsset : public Asset
{
    Q_OBJECT
public:
    explicit ReadAsset(Client * client, QObject * parent=0);
    void aSyncRead(quint64 offset, ssize_t size);

signals:
    void dataArrived(quint64 offset, ssize_t size);
};

class UploadAsset : public Asset
{
    Q_OBJECT
public:
    explicit UploadAsset(Client * client, QObject * parent=0);
    void setSize(quint64 size);

public slots:
    bool tryWrite(quint64 offset, QByteArray data);
};

#endif // ASSET_H
