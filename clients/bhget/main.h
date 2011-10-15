#ifndef MAIN_H
#define MAIN_H

#include <QtCore/QString>
#include <QtCore/QUrl>

#include <QtNetwork/QLocalSocket>
#include <QtNetwork/QTcpSocket>

#include <client.h>

struct OutQueue;

class BHGet : public QObject {
    Q_OBJECT

    QString _myName;
    QList<QUrl> _assets;
    Connection * _connection;
    Client * _client;
    ReadAsset * _asset;
    quint64 _currentOffset;
    OutQueue * _outQueue;
public:
    explicit BHGet(QString myName);
    bool queueAsset(QString uri);
    void attach(QLocalSocket & sock);

private slots:
    void onAuthenticated(QString peerName);
    void onStatusUpdate(bithorde::AssetStatus status);
    void onDataChunk(quint64 offset, QByteArray data, int tag);

private:
    void nextAsset();
    void requestMore();
};

#endif // MAIN_H
