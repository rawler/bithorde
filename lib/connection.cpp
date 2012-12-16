#include "connection.h"

#include <iostream>

#include <boost/asio.hpp>
#include <boost/bind.hpp>

#include <google/protobuf/wire_format_lite.h>
#include <google/protobuf/wire_format_lite_inl.h>
#include <google/protobuf/io/coded_stream.h>
#include <google/protobuf/io/zero_copy_stream_impl.h>

const size_t K = 1024;
const size_t M = 1024*K;
const size_t MAX_MSG = 256*K;
const size_t READ_BLOCK = MAX_MSG*2;
const size_t SEND_BUF = 16*M;
const size_t SEND_BUF_EMERGENCY = 18*M;
const size_t SEND_BUF_LOW_WATER_MARK = 2*MAX_MSG;

namespace asio = boost::asio;
namespace chrono = boost::chrono;
using namespace std;

using namespace bithorde;

template <typename Protocol>
class ConnectionImpl : public Connection {
	typedef typename Protocol::socket Socket;
	typedef typename Protocol::endpoint EndPoint;

	boost::shared_ptr<Socket> _socket;
public:
	ConnectionImpl(boost::asio::io_service& ioSvc, const EndPoint& addr) 
		: Connection(ioSvc), _socket(new Socket(ioSvc))
	{
		_socket->connect(addr);
	}

	ConnectionImpl(boost::asio::io_service& ioSvc, boost::shared_ptr<Socket>& socket)
		: Connection(ioSvc)
	{
		_socket = socket;
	}

	~ConnectionImpl() {
		close();
	}

	void trySend() {
		auto buf = _sndQueue.firstMessage();
		if (buf.size() > 0) {
			_socket->async_write_some(asio::buffer(buf),
				boost::bind(&Connection::onWritten, shared_from_this(),
							asio::placeholders::error, asio::placeholders::bytes_transferred)
			);
		}
	}

	void tryRead() {
		_socket->async_read_some(asio::buffer(_rcvBuf.allocate(MAX_MSG), MAX_MSG),
			boost::bind(&Connection::onRead, shared_from_this(),
				asio::placeholders::error, asio::placeholders::bytes_transferred
			)
		);
	}

	void close() {
		if (_socket->is_open()) {
			_socket->close();
			disconnected();
		}
	}
};

Message::Deadline Message::NEVER(Message::Deadline::max());
Message::Deadline Message::in(int msec)
{
	return Clock::now()+chrono::milliseconds(msec);
}


std::string MessageQueue::_empty;

bool MessageQueue::empty() const
{
	return _queue.empty();
}

string& MessageQueue::enqueue(const Message::Deadline& expires)
{
	_queue.push_back(Message());
	auto& newMsg = _queue.back();
	newMsg.expires = expires;
	return newMsg.buf;
}

const string& MessageQueue::firstMessage()
{
	auto now = chrono::steady_clock::now();
	while (_queue.size() && _queue.front().expires < now) {
		_queue.pop_front();
	}
	if (_queue.size()) {
		_queue.front().expires = chrono::steady_clock::time_point::max();
		return _queue.front().buf;
	} else {
		return _empty;
	}
}

void MessageQueue::pop(size_t amount)
{
	BOOST_ASSERT(_queue.size() > 0);
	auto& msg = _queue.front();
	BOOST_ASSERT(amount <= msg.buf.size());
	if (amount == msg.buf.size())
		_queue.pop_front();
	else
		msg.buf = msg.buf.substr(amount);
}

size_t MessageQueue::size() const
{
	size_t res = 0;
	for (auto iter=_queue.begin(); iter != _queue.end(); iter++) {
		res += iter->buf.size();
	}
	return res;
}

Connection::Connection(asio::io_service & ioSvc) :
	_state(Connected),
	_ioSvc(ioSvc)
{
}

Connection::Pointer Connection::create(asio::io_service& ioSvc, const boost::asio::ip::tcp::endpoint& addr)  {
	Pointer c(new ConnectionImpl<asio::ip::tcp>(ioSvc, addr));
	c->tryRead();
	return c;
}

Connection::Pointer Connection::create(asio::io_service& ioSvc, boost::shared_ptr<boost::asio::ip::tcp::socket>& socket)
{
	Pointer c(new ConnectionImpl<asio::ip::tcp>(ioSvc, socket));
	c->tryRead();
	return c;
}

Connection::Pointer Connection::create(asio::io_service& ioSvc, const boost::asio::local::stream_protocol::endpoint& addr)  {
	Pointer c(new ConnectionImpl<asio::local::stream_protocol>(ioSvc, addr));
	c->tryRead();
	return c;
}

Connection::Pointer Connection::create(asio::io_service& ioSvc, boost::shared_ptr< asio::local::stream_protocol::socket >& socket)
{
	Pointer c(new ConnectionImpl<asio::local::stream_protocol>(ioSvc, socket));
	c->tryRead();
	return c;
}

void Connection::onRead(const boost::system::error_code& err, size_t count)
{
	if (err || (count == 0)) {
		close();
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
			cerr << "BitHorde protocol warning: unknown message tag" << endl;
			res = ::google::protobuf::internal::WireFormatLite::SkipMessage(&stream);
		}
	}

	_rcvBuf.pop(_rcvBuf.size-remains);

	tryRead();
	return;
proto_error:
	cerr << "ERROR: BitHorde Protocol Error, Disconnecting" << endl;
	close();
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

bool Connection::sendMessage(Connection::MessageType type, const google::protobuf::Message& msg, const Message::Deadline& expires, bool prioritized)
{
	size_t bufLimit = prioritized ? SEND_BUF_EMERGENCY : SEND_BUF;
	if (_sndQueue.size() > bufLimit)
		return false;
	bool wasEmpty = _sndQueue.empty();

	// Encode
	{
		auto& buf = _sndQueue.enqueue(expires);
		::google::protobuf::io::StringOutputStream of(&buf);
		::google::protobuf::io::CodedOutputStream stream(&of);
		stream.WriteTag(::google::protobuf::internal::WireFormatLite::MakeTag(type, ::google::protobuf::internal::WireFormatLite::WIRETYPE_LENGTH_DELIMITED));
		stream.WriteVarint32(msg.ByteSize());
		bool encoded = msg.SerializeToCodedStream(&stream);
		BOOST_ASSERT(encoded);
	}

	// Push out at once unless _queued;
	if (wasEmpty)
		trySend();
	return true;
}

void Connection::onWritten(const boost::system::error_code& err, size_t written) {
	if ((!err) && (written > 0)) {
		_sndQueue.pop(written);
		trySend();
		if (_sndQueue.size() < SEND_BUF_LOW_WATER_MARK)
			writable();
	} else {
		cerr << "Failed to write. Disconnecting..." << endl;
		close();
	}
}
