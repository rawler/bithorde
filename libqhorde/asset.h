#ifndef ASSET_H
#define ASSET_H

#include <QObject>
#include "proto/bithorde.pb.h"

class Client;

class Asset : public QObject
{
public:
    typedef int Handle;
private:
    Q_OBJECT
    Client * _client;
    Handle _handle;
protected:
    quint64 _size;
public:
    explicit Asset(Client *parent = 0);

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
    explicit ReadAsset(Client *parent = 0);

signals:
    void dataArrived(quint64 offset, ssize_t size);

public slots:
    void aSyncRead(quint64 offset, ssize_t size);

private:
    friend class Client;
    void handleMessage(bithorde::Read_Response);
};

class UploadAsset : public Asset
{
    Q_OBJECT
public:
    explicit UploadAsset(Client *parent = 0);
    void setSize(quint64 size);

public slots:
    ssize_t tryWrite(QByteArray data);
};

#endif // ASSET_H
