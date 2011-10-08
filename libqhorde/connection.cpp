#include "connection.h"

#include <QtCore/QTextStream>

#include <google/protobuf/wire_format_lite.h>
#include <google/protobuf/wire_format_lite_inl.h>
#include <google/protobuf/io/coded_stream.h>
#include <google/protobuf/io/zero_copy_stream_impl.h>

Connection::Connection(QIODevice & socket, QObject *parent) :
    QObject(parent),
    _socket(&socket)
{
    QObject::connect(_socket, SIGNAL(connected()), this, SIGNAL(connected()));
    QObject::connect(_socket, SIGNAL(readyRead()), this, SLOT(onData()));
    _state = AwaitingConnection;
}

void Connection::onData()
{
    QByteArray buf = _socket->readAll();
    if (!_buf.isEmpty())
        buf = _buf + buf;

    ::google::protobuf::io::CodedInputStream stream((::google::protobuf::uint8*)buf.data(), buf.length());
    quint32 tag;
    bool res = true;
    size_t remains = 0;

    while (res && ((tag = stream.ReadTag()) != 0)) {
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
            res = ::google::protobuf::internal::WireFormatLite::SkipMessage(&stream);
        }
    }
    remains = stream.BytesUntilLimit();
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

void Connection::sendMessage(Connection::MessageType type, const::google::protobuf::Message &msg)
{
    ::google::protobuf::io::FileOutputStream of(socketDescriptor());
    ::google::protobuf::io::CodedOutputStream stream(&of);
    stream.WriteTag(::google::protobuf::internal::WireFormatLite::MakeTag(type, ::google::protobuf::internal::WireFormatLite::WIRETYPE_LENGTH_DELIMITED));
    stream.WriteVarint32(msg.ByteSize());
    msg.SerializeToCodedStream(&stream);
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

