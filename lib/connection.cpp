#include "connection.h"

#include "keepalive.hpp"
#include "weak_fn.hpp"

#include <boost/asio.hpp>
#include <functional>
#include <iostream>

#define CRYPTOPP_ENABLE_NAMESPACE_WEAK 1

#include <crypto++/arc4.h>
#include <crypto++/aes.h>
#include <crypto++/hmac.h>
#include <crypto++/modes.h>
#include <crypto++/sha.h>

#include <google/protobuf/wire_format_lite.h>
#include <google/protobuf/wire_format_lite_inl.h>
#include <google/protobuf/io/coded_stream.h>
#include <google/protobuf/io/zero_copy_stream_impl.h>

const size_t K = 1024;
const size_t MAX_MSG = 130*K;
const size_t MAX_ERRORS = 5;
const size_t SEND_BUF = 1024*K;
const size_t SEND_BUF_EMERGENCY = SEND_BUF + 256*K;
const size_t SEND_BUF_LOW_WATER_MARK = SEND_BUF/4;
const size_t SEND_CHUNK_MS = 50;

namespace asio = boost::asio;
using namespace std;

using namespace bithorde;

typedef CryptoPP::HMAC<CryptoPP::SHA256> HMAC_SHA256;

template <typename Protocol>
class ConnectionImpl : public Connection {
	typedef typename Protocol::socket Socket;
	typedef typename Protocol::endpoint EndPoint;

	std::shared_ptr<Socket> _socket;

	std::shared_ptr<CryptoPP::SymmetricCipher> _encryptor, _decryptor;
public:
	ConnectionImpl(boost::asio::io_service& ioSvc, const ConnectionStats::Ptr& stats, const EndPoint& addr)
		: Connection(ioSvc, stats), _socket(new Socket(ioSvc))
	{
		std::ostringstream buf;
		buf << addr;
		setLogTag(buf.str());

		_socket->connect(addr);
	}

	ConnectionImpl(boost::asio::io_service& ioSvc, const ConnectionStats::Ptr& stats, const std::shared_ptr<Socket>& socket)
		: Connection(ioSvc, stats)
	{
		std::ostringstream buf;
		buf << socket->remote_endpoint();
		setLogTag(buf.str());

		_socket = socket;
	}

	~ConnectionImpl() {
		close();
	}

	virtual void setEncryption(bithorde::CipherType t, const std::string& key, const std::string& iv) {
		switch (t) {
			case bithorde::CipherType::CLEARTEXT:
				_encryptor.reset();
				break;
			case bithorde::CipherType::AES_CTR:
				_encryptor.reset(new CryptoPP::CTR_Mode<CryptoPP::AES>::Encryption());
				_encryptor->SetKeyWithIV((const byte*)key.data(), key.size(), (const byte*)iv.data(), iv.size());
				break;
			case bithorde::CipherType::RC4:
				byte key_[HMAC_SHA256::DIGESTSIZE];
				HMAC_SHA256((const byte*)key.data(), key.size()).CalculateDigest(key_, (const byte*)iv.data(), iv.size());
				_encryptor.reset(new CryptoPP::Weak1::ARC4::Encryption());
				_encryptor->SetKey(key_, sizeof(key_));
				break;
			case bithorde::CipherType::XOR:
			default:
				throw std::runtime_error("Unsupported Cipher " + bithorde::CipherType_Name(t));
		}
	}

	virtual void setDecryption(bithorde::CipherType t, const std::string& key, const std::string& iv) {
		switch (t) {
			case bithorde::CipherType::CLEARTEXT:
				_decryptor.reset();
				break;
			case bithorde::CipherType::AES_CTR:
				_decryptor.reset(new CryptoPP::CTR_Mode<CryptoPP::AES>::Decryption());
				_decryptor->SetKeyWithIV((const byte*)key.data(), key.size(), (const byte*)iv.data(), iv.size());
				break;
			case bithorde::CipherType::RC4:
				byte key_[HMAC_SHA256::DIGESTSIZE];
				HMAC_SHA256((const byte*)key.data(), key.size()).CalculateDigest(key_, (const byte*)iv.data(), iv.size());
				_decryptor.reset(new CryptoPP::Weak1::ARC4::Decryption());
				_decryptor->SetKey(key_, sizeof(key_));
				break;
			case bithorde::CipherType::XOR:
			default:
				throw std::runtime_error("Unsupported Cipher " + bithorde::CipherType_Name(t));
		}

		// Decrypt data already in buffer
		decrypt(_rcvBuf.ptr+_rcvBuf.consumed, _rcvBuf.size-_rcvBuf.consumed);
	}

	void trySend() {
		_sendWaiting = 0;
		auto queued = _sndQueue.dequeue(_stats->outgoingBitrateCurrent.value()/8, SEND_CHUNK_MS);
		std::vector<boost::asio::const_buffer> buffers;
		buffers.reserve(queued.size());
		for (auto iter=queued.begin(); iter != queued.end(); iter++) {
			auto& buf = (*iter)->buf;
			if (_encryptor)
				_encryptor->ProcessString((byte*)buf.data(), buf.size());
			buffers.push_back(boost::asio::buffer(buf));
			_sendWaiting += buf.size();
		}
		if (_sendWaiting) {
			auto self = shared_from_this();
			boost::asio::async_write(*_socket, buffers,
				[=](const boost::system::error_code& ec, std::size_t bytes_transferred) {
					self->onWritten(ec, bytes_transferred, queued);
				}
			);
		}
		BOOST_ASSERT(_sendWaiting || _sndQueue.empty());
	}

	void tryRead() {
		if (_listening && !_readWindow) {
			auto self = shared_from_this();
			_readWindow = _rcvBuf.allocate(MAX_MSG);
			_socket->async_read_some(asio::buffer(_readWindow, MAX_MSG),
				[=](const boost::system::error_code& ec, std::size_t bytes_transferred) {
					self->onRead(ec, bytes_transferred);
				}
			);
		}
	}

	virtual void decrypt(byte* buf, size_t size) {
		if (_decryptor)
			_decryptor->ProcessString(buf, size);
	}

	void close() {
		if (_socket->is_open()) {
			_socket->close();
			disconnected();
		}
		_keepAlive.reset(NULL);
	}
};

Message::Deadline Message::NEVER(Message::Deadline::max());
Message::Deadline Message::in(int msec)
{
	return Clock::now() + std::chrono::milliseconds(msec);
}

Message::Message(Deadline expires) :
	expires(expires)
{
}

MessageQueue::MessageQueue()
	: _size(0)
{}

bool MessageQueue::empty() const
{
	return _queue.empty();
}

void MessageQueue::enqueue(const MessageQueue::MessagePtr& msg)
{
	_size += msg->buf.size();
	_queue.push_back(msg);
}

MessageQueue::MessageList MessageQueue::dequeue(size_t bytes_per_sec, ushort millis)
{
	bytes_per_sec = std::max(bytes_per_sec, 1*K);
	int32_t wanted(std::max(((bytes_per_sec*millis)/1000), static_cast<size_t>(1)));
	auto now = std::chrono::steady_clock::now();
	MessageList res;
	res.reserve(_size);
	while ((wanted > 0) && !_queue.empty()) {
		auto next = _queue.front();
		_queue.pop_front();
		_size -= next->buf.size();
		if (now < next->expires) {
			wanted -= next->buf.size();
			res.push_back(next);
		}
	}
	BOOST_ASSERT(_queue.empty() ? _size == 0 : _size > 0);
	return res;
}

size_t MessageQueue::size() const
{
	return _size;
}

ConnectionStats::ConnectionStats(const TimerService::Ptr& ts) :
	_ts(ts),
	incomingMessagesCurrent(*_ts, "msgs/s", boost::posix_time::seconds(1), 0.2),
	incomingBitrateCurrent(*_ts, "bit/s", boost::posix_time::seconds(1), 0.2),
	outgoingMessagesCurrent(*_ts, "msgs/s", boost::posix_time::seconds(1), 0.2),
	outgoingBitrateCurrent(*_ts, "bit/s", boost::posix_time::seconds(1), 0.2),
	incomingMessages("msgs"),
	incomingBytes("bytes"),
	outgoingMessages("msgs"),
	outgoingBytes("bytes")
{
}

Connection::Connection(asio::io_service & ioSvc, const ConnectionStats::Ptr& stats) :
	_ioSvc(ioSvc),
	_stats(stats),
	_listening(true),
	_readWindow(NULL),
	_sendWaiting(0),
	_errors(0)
{
}

Connection::Pointer Connection::create(asio::io_service& ioSvc, const ConnectionStats::Ptr& stats, const asio::ip::tcp::endpoint& addr)  {
	Pointer c(new ConnectionImpl<asio::ip::tcp>(ioSvc, stats, addr));
	c->tryRead();
	return c;
}

Connection::Pointer Connection::create(asio::io_service& ioSvc, const ConnectionStats::Ptr& stats, const std::shared_ptr< asio::ip::tcp::socket >& socket)
{
	Pointer c(new ConnectionImpl<asio::ip::tcp>(ioSvc, stats, socket));
	c->tryRead();
	return c;
}

Connection::Pointer Connection::create(asio::io_service& ioSvc, const ConnectionStats::Ptr& stats, const asio::local::stream_protocol::endpoint& addr)  {
	Pointer c(new ConnectionImpl<asio::local::stream_protocol>(ioSvc, stats, addr));
	c->tryRead();
	return c;
}

Connection::Pointer Connection::create(asio::io_service& ioSvc, const ConnectionStats::Ptr& stats, const std::shared_ptr< asio::local::stream_protocol::socket >& socket)
{
	Pointer c(new ConnectionImpl<asio::local::stream_protocol>(ioSvc, stats, socket));
	c->tryRead();
	return c;
}

void Connection::onRead(const boost::system::error_code& err, size_t count)
{
	if (err || (count == 0)) {
		close();
		return;
	} else {
		decrypt(_rcvBuf.ptr+_rcvBuf.size, count);
		_rcvBuf.charge(count);
		_stats->incomingBitrateCurrent += count*8;
		_stats->incomingBytes += count;
	}

	google::protobuf::io::CodedInputStream stream((::google::protobuf::uint8*)_rcvBuf.ptr, _rcvBuf.size);
	bool res = true;
	size_t msgs_processed(0);
	while (res) {
		uint32_t tag = stream.ReadTag();
		if (tag == 0)
			break;
		switch (::google::protobuf::internal::WireFormatLite::GetTagFieldNumber(tag)) {
		case HandShake:
			res = dequeue<bithorde::HandShake>(HandShake, stream); msgs_processed++; break;
		case BindRead:
			res = dequeue<bithorde::BindRead>(BindRead, stream); msgs_processed++; break;
		case AssetStatus:
			res = dequeue<bithorde::AssetStatus>(AssetStatus, stream); msgs_processed++; break;
		case ReadRequest:
			res = dequeue<bithorde::Read::Request>(ReadRequest, stream); msgs_processed++; break;
		case ReadResponse:
			res = dequeue<bithorde::Read::Response>(ReadResponse, stream); msgs_processed++; break;
		case BindWrite:
			res = dequeue<bithorde::BindWrite>(BindWrite, stream); msgs_processed++; break;
		case DataSegment:
			res = dequeue<bithorde::DataSegment>(DataSegment, stream); msgs_processed++; break;
		case HandShakeConfirmed:
			res = dequeue<bithorde::HandShakeConfirmed>(HandShakeConfirmed, stream); msgs_processed++; break;
		case Ping:
			res = dequeue<bithorde::Ping>(Ping, stream); msgs_processed++; break;
		default:
			cerr << _logTag << ": BitHorde protocol warning: unknown message tag" << endl;
			if (++_errors > MAX_ERRORS) {
				cerr << _logTag << ": Excessive errors. Closing." << endl;
				return close();
			}
			res = ::google::protobuf::internal::WireFormatLite::SkipMessage(&stream);
		}
	}

	if (msgs_processed && _keepAlive) {
		_errors = 0;
		_keepAlive->reset();
	}
	_readWindow = NULL;
	_rcvBuf.pop();

	tryRead();
	return;
}

template <class T>
bool Connection::dequeue(MessageType type, ::google::protobuf::io::CodedInputStream &stream) {
	bool res;
	T msg;

	uint32_t length;
	if (!stream.ReadVarint32(&length)) return false;

	int bytesLeft = stream.BytesUntilLimit();
	BOOST_ASSERT(bytesLeft >= 0);
	int leftInBuffer = bytesLeft-length;
	if (leftInBuffer < 0) return false;

	_stats->incomingMessages += 1;
	_stats->incomingMessagesCurrent += 1;
	::google::protobuf::io::CodedInputStream::Limit limit = stream.PushLimit(length);
	if ((res = msg.MergePartialFromCodedStream(&stream))) {
		_rcvBuf.consume(_rcvBuf.left() - leftInBuffer);
		_dispatch(type, msg);
	}
	stream.PopLimit(limit);

	return res;
}

void Connection::setCallback(const Connection::Callback& cb) {
	_dispatch = cb;
}

void Connection::setKeepalive(Keepalive* value)
{
	_keepAlive.reset(value);
}

ConnectionStats::Ptr Connection::stats()
{
	return _stats;
}

void Connection::setLogTag(const std::string& tag)
{
	_logTag = tag;
}

bool Connection::sendMessage(Connection::MessageType type, const google::protobuf::Message& msg, const Message::Deadline& expires, bool prioritized)
{
	size_t bufLimit = prioritized ? SEND_BUF_EMERGENCY : SEND_BUF;
	if (_sndQueue.size() > bufLimit) {
		if (prioritized) {
			cerr << _logTag << ": Prioritized overflow. Closing." << endl;
			close();
		}
		return false;
	}

	std::shared_ptr<Message> buf(new Message(expires));
	// Encode
	{
		::google::protobuf::io::StringOutputStream of(&buf->buf);
		::google::protobuf::io::CodedOutputStream stream(&of);
		stream.WriteTag(::google::protobuf::internal::WireFormatLite::MakeTag(type, ::google::protobuf::internal::WireFormatLite::WIRETYPE_LENGTH_DELIMITED));
		stream.WriteVarint32(msg.ByteSize());
		BOOST_VERIFY( msg.SerializeToCodedStream(&stream) );
	}
	_sndQueue.enqueue(buf);

	_stats->outgoingMessages += 1;
	_stats->outgoingMessagesCurrent += 1;

	// Push out at once unless _queued;
	if (_sendWaiting == 0)
		trySend();
	return true;
}

void Connection::setListening ( bool listening ) {
	if (_listening == listening )
		return;

	_listening = listening;
	if (_listening) {
		tryRead();
	}
}

void Connection::onWritten(const boost::system::error_code& err, size_t written, const MessageQueue::MessageList& queued) {
	size_t queued_bytes(0);
	for (auto iter=queued.begin(); iter != queued.end(); iter++) {
		queued_bytes += (*iter)->buf.size();
	}
	if ((!err) && (written == queued_bytes) && (written>0)) {
		_stats->outgoingBitrateCurrent += written*8;
		_stats->outgoingBytes += written;
		trySend();
		if (_sndQueue.size() < SEND_BUF_LOW_WATER_MARK)
			writable();
	} else {
		if (err == boost::system::errc::broken_pipe) {
			cerr << _logTag << ": Disconnected..." << endl;
		} else {
			cerr << _logTag << ": Failed to write. (" << err.message() << ") Disconnecting..." << endl;
		}
		close();
	}
}
