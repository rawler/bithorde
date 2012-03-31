#ifndef BITHORDE_CLIENT_H
#define BITHORDE_CLIENT_H

#include <map>
#include <string>

#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/local/stream_protocol.hpp>
#include <boost/bind.hpp>
#include <boost/make_shared.hpp>
#include <boost/signals2.hpp>

#include "asset.h"
#include "connection.h"
#include "allocator.h"

namespace bithorde {

class Client
{
	boost::asio::io_service& _ioSvc;
	Connection::Pointer _connection;

	std::string _myName;
	std::string _peerName;

	std::map<Asset::Handle, Asset*> _assetMap;
	std::map<int, Asset::Handle> _requestIdMap;
	CachedAllocator<Asset::Handle> _handleAllocator;
	CachedAllocator<int> _rpcIdAllocator;

	uint8_t _protoVersion;
public:
	typedef boost::shared_ptr<Client> Pointer;

	static Pointer create(boost::asio::io_service& ioSvc, std::string myName) {
		return Pointer(new Client(ioSvc, myName));
	}

	/**
	 * Tries to parse spec either as HOST:PORT, or as /absolute/socket/path and connect to it. 
	 */
	void connect(std::string spec);

	void connect(boost::asio::ip::tcp::endpoint& ep);
	void connect(boost::asio::local::stream_protocol::endpoint& ep);
	void connect(Connection::Pointer newConn);

	bool isConnected();
	const std::string& peerName();

	bool bind(ReadAsset & asset);
	bool bind(UploadAsset & asset);

	bool sendMessage(Connection::MessageType type, const ::google::protobuf::Message & msg);

	boost::signals2::signal<void (std::string&)> authenticated;
	boost::signals2::signal<void ()> writable;
	boost::signals2::signal<void ()> disconnected;

protected:
	Client(boost::asio::io_service& ioSvc, std::string myName);

	void sayHello();

	void onDisconnected();
	void onIncomingMessage(Connection::MessageType type, ::google::protobuf::Message& msg);

	virtual void onMessage(const bithorde::HandShake & msg);
	virtual void onMessage(const bithorde::BindRead & msg);
	virtual void onMessage(const bithorde::AssetStatus & msg);
	virtual void onMessage(const bithorde::Read::Request & msg);
	virtual void onMessage(const bithorde::Read::Response & msg);
	virtual void onMessage(const bithorde::BindWrite & msg);
	virtual void onMessage(const bithorde::DataSegment & msg);
	virtual void onMessage(const bithorde::HandShakeConfirmed & msg);
	virtual void onMessage(const bithorde::Ping & msg);

private:
	friend class Asset;
	friend class ReadAsset;
	bool release(Asset & a);

	boost::signals2::scoped_connection _messageConnection;
	boost::signals2::scoped_connection _writableConnection;
	boost::signals2::scoped_connection _disconnectedConnection;

	bool informBound(const ReadAsset&);
	int allocRPCRequest(Asset::Handle asset);
	void releaseRPCRequest(int reqId);
};

}

#endif // BITHORDE_CLIENT_H
