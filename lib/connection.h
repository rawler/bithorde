#ifndef CONNECTION_H
#define CONNECTION_H

#include <queue>

#include <boost/asio.hpp>
#include <boost/signal.hpp>

#include "bithorde.pb.h"
#include "types.h"

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
	enum State {
		Connecting,
		Connected,
		AwaitingAuth,
		Authenticated,
	};

	static Pointer create(boost::asio::io_service& ioSvc, const boost::asio::local::stream_protocol::endpoint& addr) {
		Pointer c(new Connection(ioSvc, addr));
		c->tryRead();
		return c;
	}
	~Connection();

	boost::signal<void ()> disconnected;
	boost::signal<void (MessageType, ::google::protobuf::Message&)> message;
	boost::signal<void ()> writable;

public:
	bool sendMessage(MessageType type, const ::google::protobuf::Message & msg, bool prioritized=false);

protected:
	Connection(boost::asio::io_service& ioSvc, const boost::asio::local::stream_protocol::endpoint& addr);

	void tryRead();
	
	void onRead(const boost::system::error_code& err, size_t count);
	void onWritten(const boost::system::error_code& err, size_t count);

	bool encode(Connection::MessageType type, const::google::protobuf::Message &msg);
	void trySend();
private:
	State _state;

	boost::asio::local::stream_protocol::socket _socket;
	boost::asio::io_service& _ioSvc;

	Buffer _rcvBuf;
	Buffer _sendBuf;

	template <class T> bool dequeue(MessageType type, ::google::protobuf::io::CodedInputStream &stream);
};

#endif // CONNECTION_H
