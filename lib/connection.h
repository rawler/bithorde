#ifndef BITHORDE_CONNECTION_H
#define BITHORDE_CONNECTION_H


#include <boost/asio/io_service.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/local/stream_protocol.hpp>
#include <boost/chrono/system_clocks.hpp>
#include <boost/signals2.hpp>
#include <boost/smart_ptr/enable_shared_from_this.hpp>
#include <list>

#include "bithorde.pb.h"
#include "counter.h"
#include "timer.h"
#include "types.h"

namespace bithorde {

class Keepalive;

struct Message {
	typedef boost::chrono::steady_clock Clock;
	typedef Clock::time_point Deadline;
	static Deadline NEVER;
	static Deadline in(int msec);

	Message(Deadline expires);
	std::string buf; // TODO: test if ostringstream faster
	boost::chrono::steady_clock::time_point expires;
};

class MessageQueue : boost::noncopyable {
public:
	typedef boost::shared_ptr<const Message> MessagePtr;
	typedef std::vector< MessagePtr > MessageList;
private:
	std::list< MessagePtr > _queue;
	std::size_t _size;
public:
	MessageQueue();
	bool empty() const;

	/**
	 * Note: queue takes ownership of the message
	 */
	void enqueue(const MessagePtr& msg);

	/**
	 * Note: relinquishes ownership of the messages
	 */
	MessageList dequeue(std::size_t bytes_per_sec, ushort millis);
	std::size_t size() const;
};

class ConnectionStats {
	TimerService::Ptr _ts;
public:
	typedef boost::shared_ptr<ConnectionStats> Ptr;

	LazyCounter incomingMessagesCurrent, incomingBitrateCurrent;
	LazyCounter outgoingMessagesCurrent, outgoingBitrateCurrent;
	Counter incomingMessages, incomingBytes;
	Counter outgoingMessages, outgoingBytes;

	ConnectionStats(const TimerService::Ptr& ts);
};

class Connection
	: public boost::enable_shared_from_this<Connection>
{
public:
	typedef boost::shared_ptr<Connection> Pointer;

	enum MessageType {
		HandShake = 1,
		BindRead = 2,
		AssetStatus = 3,
		ReadRequest = 5,
		ReadResponse = 6,
		BindWrite = 7,
		DataSegment = 8,
		HandShakeConfirmed = 9,
		Ping = 10,
	};

	static Pointer create(boost::asio::io_service& ioSvc, const bithorde::ConnectionStats::Ptr& stats, const boost::asio::ip::tcp::endpoint& addr);
	static Pointer create(boost::asio::io_service& ioSvc, const bithorde::ConnectionStats::Ptr& stats, boost::shared_ptr< boost::asio::ip::tcp::socket >& socket);
	static Pointer create(boost::asio::io_service& ioSvc, const bithorde::ConnectionStats::Ptr& stats, const boost::asio::local::stream_protocol::endpoint& addr);
	static Pointer create(boost::asio::io_service& ioSvc, const bithorde::ConnectionStats::Ptr& stats, boost::shared_ptr< boost::asio::local::stream_protocol::socket >& socket);

	virtual void setEncryption(bithorde::CipherType t, const std::string& key, const std::string& iv) = 0;
	virtual void setDecryption(bithorde::CipherType t, const std::string& key, const std::string& iv) = 0;
	void setKeepalive(Keepalive* keepalive);

	typedef boost::signals2::signal<void ()> VoidSignal;
	typedef boost::signals2::signal<void (MessageType, ::google::protobuf::Message&)> MessageSignal;
	VoidSignal disconnected;
	MessageSignal message;
	VoidSignal writable;

	ConnectionStats::Ptr stats();
	void setLogTag(const std::string& tag);

	bool sendMessage(MessageType type, const ::google::protobuf::Message & msg, const Message::Deadline& expires, bool prioritized);

	virtual void close() = 0;

protected:
	Connection(boost::asio::io_service& ioSvc, const bithorde::ConnectionStats::Ptr& stats);

	virtual void trySend() = 0;
	virtual void tryRead() = 0;
	virtual void decrypt(byte* buf, size_t size) = 0;

	void onRead(const boost::system::error_code& err, size_t count);
	void onWritten(const boost::system::error_code& err, std::size_t written, const MessageQueue::MessageList& queued);

protected:
	boost::asio::io_service& _ioSvc;
	ConnectionStats::Ptr _stats;
	std::unique_ptr<Keepalive> _keepAlive;
	std::string _logTag;

	Buffer _rcvBuf;
	MessageQueue _sndQueue;
	size_t _sendWaiting;
	uint32_t _errors;
private:
	template <class T> bool dequeue(MessageType type, ::google::protobuf::io::CodedInputStream &stream);
};

}

#endif // BITHORDE_CONNECTION_H
