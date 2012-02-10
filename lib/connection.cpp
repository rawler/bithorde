#include "connection.h"

#include <iostream>

#include <boost/bind.hpp>

#include <google/protobuf/wire_format_lite.h>
#include <google/protobuf/wire_format_lite_inl.h>
#include <google/protobuf/io/coded_stream.h>
#include <google/protobuf/io/zero_copy_stream_impl.h>

const size_t MAX_MSG = 64*1024;
const size_t READ_BLOCK = MAX_MSG*2;
const size_t SEND_BUF = 1024*1024;
const size_t SEND_BUF_EMERGENCY = 2*SEND_BUF;
const size_t SEND_BUF_LOW_WATER_MARK = MAX_MSG;

namespace asio = boost::asio;
using namespace std;

Connection::Connection(boost::asio::io_service& ioSvc, const boost::asio::local::stream_protocol::endpoint& addr) :
	_state(Connected),
	_socket(ioSvc),
	_ioSvc(ioSvc)
{
	_socket.connect(addr);

	_sendBuf.allocate(SEND_BUF_EMERGENCY); // Prepare so we don't have to move it later during async send.
}

Connection::~Connection() {
// 	disconnected();
}

void Connection::tryRead() {
	_socket.async_read_some(asio::buffer(_rcvBuf.allocate(MAX_MSG), MAX_MSG),
		boost::bind(&Connection::onRead, shared_from_this(),
			asio::placeholders::error, asio::placeholders::bytes_transferred
		)
	);
}

void Connection::onRead(const boost::system::error_code& err, size_t count)
{
	if (err || count == 0) {
		// TODO: Close and signal closed to upstream. This, with it's socket, will be deleted when all references are cleared
		return;
	} else {
		_rcvBuf.charge(count);
	}

	google::protobuf::io::CodedInputStream stream((::google::protobuf::uint8*)_rcvBuf.ptr, _rcvBuf.size);
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
			// TODO: _logger.warning("unknown message tag");
			res = ::google::protobuf::internal::WireFormatLite::SkipMessage(&stream);
		}
	}

	_rcvBuf.pop(_rcvBuf.size-remains);

	tryRead();
	return;
proto_error:
	// TODO: _logger.error("ERROR: BitHorde Protocol Error, Disconnecting");
	return;
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
		message(type, msg);
	}
	stream.PopLimit(limit);

	return res;
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
	bool prevQueued = _sendBuf.size;

	bool queued = encode(type, msg);
	if (queued) {
		if (!prevQueued)
			trySend();
		return true;
	} else {
		// TODO: _logger.error("Failed to serialize Message.");
		return false;
	}
}

void Connection::trySend() {
	cerr.flush();

	if (_sendBuf.size) {
		_socket.async_write_some(asio::buffer(_sendBuf.ptr, _sendBuf.size),
			boost::bind(&Connection::onWritten, shared_from_this(),
						asio::placeholders::error, asio::placeholders::bytes_transferred)
		);
	}
}

void Connection::onWritten(const boost::system::error_code& err, size_t written) {
	if (written >= 0) {
		_sendBuf.pop(written);
		trySend();
		if (_sendBuf.size < SEND_BUF_LOW_WATER_MARK)
			writable();
	} else {
		// TODO: _logger.error("Failed to write. Disconnecting...");
	}
}
