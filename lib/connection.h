#ifndef CONNECTION_H
#define CONNECTION_H

#include <queue>

#include <Poco/BasicEvent.h>
#include <Poco/EventArgs.h>
#include <Poco/Net/StreamSocket.h>
#include <Poco/Net/SocketNotification.h>
#include <Poco/Net/SocketReactor.h>
#include <Poco/Logger.h>

#include "bithorde.pb.h"
#include "types.h"

class Connection
{
public:
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

	Connection();
	Connection(Poco::Net::StreamSocket & socket, Poco::Net::SocketReactor& reactor);
	~Connection();

	struct Message {
		Connection::MessageType type;
		const ::google::protobuf::Message & content;
		Message(Connection::MessageType type, const google::protobuf::Message & content) :
			type(type),
			content(content)
		{}
	};
	Poco::BasicEvent<Poco::EventArgs> disconnected;
	Poco::BasicEvent<Message> message;
	Poco::BasicEvent<Poco::EventArgs> sent;

public:
	// TODO: Support "prioritized" messages, I.E. Binding changes.
	bool sendMessage(MessageType type, const ::google::protobuf::Message & msg);

protected:
	void onError(const Poco::AutoPtr<Poco::Net::ErrorNotification>& pNf);
	void onReadable(const Poco::AutoPtr<Poco::Net::ReadableNotification>& pNf);
	void onWritable(const Poco::AutoPtr<Poco::Net::WritableNotification>& pNf);

	bool encode(Connection::MessageType type, const::google::protobuf::Message &msg);
	void trySend();
private:
	State _state;
	Poco::Logger& _logger;

	Poco::Net::StreamSocket _socket;
	Poco::Net::SocketReactor& _reactor; 

	Buffer _rcvBuf;
	Buffer _sendBuf;

	template <class T> bool dequeue(MessageType type, ::google::protobuf::io::CodedInputStream &stream);
};

#endif // CONNECTION_H
