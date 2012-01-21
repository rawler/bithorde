#include "connection.h"

#include <iostream>

#include <google/protobuf/wire_format_lite.h>
#include <google/protobuf/wire_format_lite_inl.h>
#include <google/protobuf/io/coded_stream.h>
#include <google/protobuf/io/zero_copy_stream_impl.h>

#include <Poco/Net/SocketNotification.h>
#include <Poco/NObserver.h>
#include <Poco/Util/Application.h>

const size_t READ_BLOCK = 65536;
const size_t MAX_MSG = 256*1024;
const size_t SEND_BUF = 1024*1024;
const size_t SEND_BUF_EMERGENCY = 2*SEND_BUF;
const size_t SEND_BUF_LOW_WATER_MARK = MAX_MSG;

using namespace std;
using namespace Poco;
using namespace Poco::Net;
using namespace Poco::Util;

Connection::Connection(StreamSocket & socket, SocketReactor& reactor) :
	_state(Connected),
	_logger(Application::instance().logger()),
	_socket(socket),
	_reactor(reactor)
{
	Application& app = Application::instance();
	app.logger().information("Connection from " + socket.peerAddress().toString());

	_reactor.addEventHandler(_socket, NObserver<Connection, ReadableNotification>(*this, &Connection::onReadable));
	_reactor.addEventHandler(_socket, NObserver<Connection, ErrorNotification>(*this, &Connection::onError));
}

Connection::~Connection() {
	disconnected.notify(this, NO_ARGS);
	_reactor.removeEventHandler(_socket, NObserver<Connection, ReadableNotification>(*this, &Connection::onReadable));
	_reactor.removeEventHandler(_socket, NObserver<Connection, ErrorNotification>(*this, &Connection::onError));
}

void Connection::onReadable(const AutoPtr<ReadableNotification>& pNf)
{
	byte* buf = _rcvBuf.allocate(READ_BLOCK);
	size_t read = _socket.receiveBytes(buf, READ_BLOCK);
	if (read >= 0) {
		_rcvBuf.charge(read);
	} else if (read == 0) {
		_logger.information("Closing connection from " + _socket.peerAddress().toString());
		delete this;
	} else {
		_logger.error("Error on " + _socket.peerAddress().toString());
		delete this;
	}

	::google::protobuf::io::CodedInputStream stream((::google::protobuf::uint8*)_rcvBuf.ptr, _rcvBuf.size);
	bool res = true;
	size_t remains;
	while (res) {
		remains = stream.BytesUntilLimit();
		uint32_t tag = stream.ReadTag();
		if (tag == 0)
			break;
		switch (::google::protobuf::internal::WireFormatLite::GetTagFieldNumber(tag)) {
		case HandShake:
			if (_state != Connected) goto proto_error;
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
			_logger.warning("unknown message tag");
			res = ::google::protobuf::internal::WireFormatLite::SkipMessage(&stream);
		}
	}

	_rcvBuf.pop(_rcvBuf.size-remains);

	return;
proto_error:
	_logger.error("ERROR: BitHorde Protocol Error, Disconnecting");
	delete this;
}

template <class T>
bool Connection::dequeue(MessageType type, ::google::protobuf::io::CodedInputStream &stream) {
	bool res;
	T msg;

	uint32_t length;
	if (!stream.ReadVarint32(&length)) return false;

	uint32_t bytesLeft = stream.BytesUntilLimit();
	if (length > bytesLeft) return false;

	::google::protobuf::io::CodedInputStream::Limit limit = stream.PushLimit(length);
	if ((res = msg.MergePartialFromCodedStream(&stream))) {
		Message msg_(type, msg);
		message.notify(this, msg_);
	}
	stream.PopLimit(limit);

	return res;
}

void Connection::onError(AutoPtr<Poco::Net::ErrorNotification> const& pNf) {
	_logger.error("Error on connection");
	delete this;
}

bool Connection::encode(Connection::MessageType type, const google::protobuf::Message &msg) {
	byte* buf = _sendBuf.allocate(MAX_MSG);
	::google::protobuf::io::ArrayOutputStream of(buf, MAX_MSG);
	::google::protobuf::io::CodedOutputStream stream(&of);
	stream.WriteTag(::google::protobuf::internal::WireFormatLite::MakeTag(type, ::google::protobuf::internal::WireFormatLite::WIRETYPE_LENGTH_DELIMITED));
	stream.WriteVarint32(msg.ByteSize());
	bool res = msg.SerializeToCodedStream(&stream);
	if (res)
		_sendBuf.charge(stream.ByteCount());
	return res;
}

bool Connection::sendMessage(Connection::MessageType type, const::google::protobuf::Message &msg, bool prioritized)
{
	size_t bufLimit = prioritized ? SEND_BUF_EMERGENCY : SEND_BUF;
	if (_sendBuf.size > bufLimit)
		return false;

	bool queued = encode(type, msg);
	if (queued) {
		trySend();
		return true;
	} else {
		_logger.error("Failed to serialize Message.");
		return false;
	}
}

void Connection::trySend() {
	int written = _socket.sendBytes(_sendBuf.ptr, _sendBuf.size);
	if (written >= 0) {
		_sendBuf.pop(written);
		if (_sendBuf.size)
			_reactor.addEventHandler(_socket, NObserver<Connection, WritableNotification>(*this, &Connection::onWritable));
		else // TODO: Handle onWritable and unregister smarter
			_reactor.removeEventHandler(_socket, NObserver<Connection, WritableNotification>(*this, &Connection::onWritable));
		if (_sendBuf.size < SEND_BUF_LOW_WATER_MARK)
			writable.notify(this, NO_ARGS);
	} else {
		_logger.error("Failed to write. Disconnecting...");
		delete this;
	}
}

void Connection::onWritable(AutoPtr<WritableNotification> const& pNf) {
	trySend();
}
