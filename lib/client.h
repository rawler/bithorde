#ifndef BITHORDE_CLIENT_H
#define BITHORDE_CLIENT_H

#include <map>
#include <string>

#include <boost/asio/deadline_timer.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/local/stream_protocol.hpp>
#include <boost/bind.hpp>
#include <boost/make_shared.hpp>
#include <boost/signals2.hpp>

#include "asset.h"
#include "connection.h"
#include "allocator.h"

namespace bithorde {

class Client;

class AssetBinding {
	friend class Client;

	Client* _client;
	Asset* _asset;
	Asset::Handle _handle;
	boost::asio::deadline_timer _statusTimer;
public:
	AssetBinding(Client* client, Asset* asset, Asset::Handle handle);

	Asset* asset() const;

	/** Returns a valid pointer if current binding is a readasset, otherwise NULL */
	ReadAsset* readAsset() const;

	operator bool() const { return _asset; }
	Asset* operator->() const { return _asset; }

	void close();
private:
	void setTimer(const boost::posix_time::time_duration& timeout);
	void clearTimer();
	void onTimeout(const boost::system::error_code& error);
};

class Client
{
	friend class AssetBinding;
	friend class Asset;
	friend class ReadAsset;

	typedef std::unique_ptr<AssetBinding> AssetPtr;

	boost::asio::io_service& _ioSvc;
	Connection::Pointer _connection;

	std::string _myName;
	std::string _peerName;

	std::map<Asset::Handle, AssetPtr> _assetMap;
	std::map<int, Asset::Handle> _requestIdMap;
	CachedAllocator<Asset::Handle> _handleAllocator;
	CachedAllocator<int> _rpcIdAllocator;

	uint8_t _protoVersion;
public:
	typedef boost::shared_ptr<Client> Pointer;
	typedef boost::weak_ptr<Client> WeakPtr;

	static Pointer create(boost::asio::io_service& ioSvc, std::string myName) {
		return Pointer(new Client(ioSvc, myName));
	}
	virtual ~Client() {}

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
	bool bind(ReadAsset & asset, uint64_t uuid, int timeout);
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
	virtual void onMessage(bithorde::BindRead& msg);
	virtual void onMessage(const bithorde::AssetStatus & msg);
	virtual void onMessage(const bithorde::Read::Request & msg);
	virtual void onMessage(const bithorde::Read::Response & msg);
	virtual void onMessage(const bithorde::BindWrite & msg);
	virtual void onMessage(const bithorde::DataSegment & msg);
	virtual void onMessage(const bithorde::HandShakeConfirmed & msg);
	virtual void onMessage(const bithorde::Ping & msg);

private:
	bool release(Asset & a);

	boost::signals2::scoped_connection _messageConnection;
	boost::signals2::scoped_connection _writableConnection;
	boost::signals2::scoped_connection _disconnectedConnection;

	bool informBound(const bithorde::AssetBinding& asset, uint64_t uuid, int timeout);
	int allocRPCRequest(Asset::Handle asset);
	void releaseRPCRequest(int reqId);
};

}

#endif // BITHORDE_CLIENT_H
