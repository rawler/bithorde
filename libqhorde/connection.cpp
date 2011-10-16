#include "connection.h"

#include <QtCore/QTextStream>

#include <google/protobuf/wire_format_lite.h>
#include <google/protobuf/wire_format_lite_inl.h>
#include <google/protobuf/io/coded_stream.h>
#include <google/protobuf/io/zero_copy_stream_impl.h>

#define MAX_QUEUE 20

Connection::Connection(QIODevice & socket, QObject *parent) :
    QObject(parent),
    _socket(&socket)
{
    QObject::connect(_socket, SIGNAL(connected()), this, SIGNAL(connected()));
    QObject::connect(_socket, SIGNAL(bytesWritten(qint64)), this, SIGNAL(sent()));
    QObject::connect(_socket, SIGNAL(readyRead()), this, SLOT(onData()));
    _state = AwaitingConnection;
}

void Connection::onData()
{
    QByteArray buf = _socket->readAll();
    if (!_buf.isEmpty())
        buf = _buf + buf;

    ::google::protobuf::io::CodedInputStream stream((::google::protobuf::uint8*)buf.data(), buf.length());
    bool res = true;
    size_t remains;
    while (res) {
        remains = stream.BytesUntilLimit();
        quint32 tag = stream.ReadTag();
        if (tag == 0)
            break;
        switch (::google::protobuf::internal::WireFormatLite::GetTagFieldNumber(tag)) {
        case HandShake:
            if (_state == Connected) goto proto_error;
            res = dequeue<bithorde::HandShake>(HandShake, stream); break;
        case BindRead:
            if (_state == Authenticated) goto proto_error;
            res = dequeue<bithorde::BindRead>(BindRead, stream); break;
        case AssetStatus:
            if (_state == Authenticated) goto proto_error;
            res = dequeue<bithorde::AssetStatus>(AssetStatus, stream); break;
        case ReadRequest:
            if (_state == Authenticated) goto proto_error;
            res = dequeue<bithorde::Read::Request>(ReadRequest, stream); break;
        case ReadResponse:
            if (_state == Authenticated) goto proto_error;
            res = dequeue<bithorde::Read::Response>(ReadResponse, stream); break;
        case BindWrite:
            if (_state == Authenticated) goto proto_error;
            res = dequeue<bithorde::BindWrite>(BindWrite, stream); break;
        case DataSegment:
            if (_state == Authenticated) goto proto_error;
            res = dequeue<bithorde::DataSegment>(DataSegment, stream); break;
        case HandShakeConfirmed:
            if (_state != AwaitingAuth) goto proto_error;
            res = dequeue<bithorde::HandShakeConfirmed>(HandShakeConfirmed, stream); break;
        case Ping:
            if (_state == Authenticated) goto proto_error;
            res = dequeue<bithorde::Ping>(Ping, stream); break;
        default:
            QTextStream(stderr) << "unknown message tag\n";
            res = ::google::protobuf::internal::WireFormatLite::SkipMessage(&stream);
        }
    }

    if (remains) {
        _buf = buf.right(remains);
    } else {
        _buf.clear();
    }

    return;
proto_error:
    QTextStream(stderr) << "ERROR: BitHorde Protocol Error, Disconnecting\n";
    _socket->close();
}

template <class T>
bool Connection::dequeue(MessageType type, ::google::protobuf::io::CodedInputStream &stream) {
    T msg;
    if (::google::protobuf::internal::WireFormatLite::ReadMessageNoVirtual(&stream, &msg)) {
        emit message(type, msg);
        return true;
    } else {
        return false;
    }
}

bool encode(std::string* target, Connection::MessageType type, const::google::protobuf::Message &msg) {
    ::google::protobuf::io::StringOutputStream of(target);
    ::google::protobuf::io::CodedOutputStream stream(&of);
    stream.WriteTag(::google::protobuf::internal::WireFormatLite::MakeTag(type, ::google::protobuf::internal::WireFormatLite::WIRETYPE_LENGTH_DELIMITED));
    stream.WriteVarint32(msg.ByteSize());
    return msg.SerializeToCodedStream(&stream);
}

bool Connection::sendMessage(Connection::MessageType type, const::google::protobuf::Message &msg)
{
    if (_socket->bytesToWrite() > 512*1024)
        return false;

    std::string buf;
    bool success = encode(&buf, type, msg);
    Q_ASSERT(success);

    qint64 written = 0;
    written = _socket->write(buf.data(), buf.length());
    Q_ASSERT(written == buf.length());

    return success && written;
}

TCPConnection::TCPConnection(QTcpSocket & socket) :
    Connection(socket),
    _socket(&socket)
{}
int TCPConnection::socketDescriptor()
{
    return _socket->socketDescriptor();
}
bool TCPConnection::isConnected() {
    return _socket->state() == QTcpSocket::ConnectedState;
}

LocalConnection::LocalConnection(QLocalSocket & socket) :
    Connection(socket),
    _socket(&socket)
{}
int LocalConnection::socketDescriptor()
{
    return _socket->socketDescriptor();
}
bool LocalConnection::isConnected() {
    return _socket->state() == QLocalSocket::ConnectedState;
}

