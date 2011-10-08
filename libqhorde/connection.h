#ifndef CONNECTION_H
#define CONNECTION_H

#include <QtCore/QByteArray>
#include <QtCore/QIODevice>

#include <QtNetwork/QLocalSocket>
#include <QtNetwork/QTcpSocket>

#include "proto/bithorde.pb.h"

class Connection : public QObject
{
    Q_OBJECT
public:
    enum MessageType {
        HandShake = 1,
        BindRead = 2,
        AssetStatus = 3,
        ReadRequest = 4,
        ReadResponse = 5,
        BindWrite = 7,
        DataSegment = 8,
        HandShakeConfirmed = 9,
        Ping = 10,
    };
    enum State {
        AwaitingConnection,
        Connected,
        AwaitingAuth,
        Authenticated,
    };

    explicit Connection(QIODevice & socket, QObject *parent = 0);
    virtual bool isConnected() = 0;

signals:
    void connected();
    void disconnected();
    void message(Connection::MessageType type, const ::google::protobuf::Message & msg);

public slots:
    void onData();
    void sendMessage(MessageType type, const ::google::protobuf::Message & msg);

protected:
    virtual int socketDescriptor() = 0;

private:
    State _state;

    QIODevice * _socket;
    QByteArray _buf;

    template <class T> bool dequeue(MessageType type, ::google::protobuf::io::CodedInputStream &stream);
};

class TCPConnection : public Connection {
    Q_OBJECT
    QTcpSocket * _socket;
public:
    explicit TCPConnection(QTcpSocket & socket);

    virtual int socketDescriptor();
    virtual bool isConnected();
};

class LocalConnection : public Connection {
    Q_OBJECT
    QLocalSocket * _socket;
public:
    explicit LocalConnection(QLocalSocket & socket);

    virtual int socketDescriptor();
    virtual bool isConnected();
};

#endif // CONNECTION_H
