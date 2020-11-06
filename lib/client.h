#ifndef BITHORDE_CLIENT_H
#define BITHORDE_CLIENT_H

#include <functional>
#include <map>
#include <string>

#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/local/stream_protocol.hpp>
#include <boost/signals2.hpp>

#include "allocator.h"
#include "asset.h"
#include "connection.h"
#include "timer.h"

namespace bithorde {

const boost::posix_time::millisec DEFAULT_ASSET_TIMEOUT(1500);
const boost::posix_time::millisec UPLOAD_ASSET_TIMEOUT(15000);
const boost::posix_time::millisec CLOSE_TIMEOUT(DEFAULT_ASSET_TIMEOUT);
const int MAX_ASSETS(1024);

class Client;
class ClientKeepalive;

class AssetBinding {
	friend class Client;

	Client* _client;
	Asset* _asset;
	Asset::Handle _handle;
	Timer _statusTimer;
	boost::posix_time::ptime _opened_at;

	RouteTrace _requesters;
public:
	AssetBinding(Client* client, Asset* asset, Asset::Handle handle);

	Asset* asset() const;

	/** Returns a valid pointer if current binding is a readasset, otherwise NULL */
	ReadAsset* readAsset() const;

	operator bool() const { return _asset; }
	Asset* operator->() const { return _asset; }

	const RouteTrace& requesters() const { return _requesters; }
	RouteTrace& requesters() { return _requesters; }

	void close();
private:
	void setTimer(const boost::posix_time::time_duration& timeout);
	void clearTimer();
	void orphaned();
	void onTimeout();
};

template <typename T>
class MessageContext;

struct CipherConfig;
class Client
	: public std::enable_shared_from_this<Client>
{
public:
	enum State {
		Connecting    = 0x00,
		Connected     = 0x01,
		SaidHello     = 0x02,
		SentAuth      = 0x04,
		GotAuth       = 0x08,
		Authenticated = Connected|SaidHello|SentAuth|GotAuth,
	};
private:
	friend class AssetBinding;
	friend class Asset;
	friend class ReadAsset;
	friend class ReadRequestContext;

	typedef std::shared_ptr<AssetBinding> AssetPtr;
	typedef std::map<Asset::Handle, AssetPtr> AssetMap;

	boost::asio::io_context& _ioCtx;
	TimerService::Ptr _timerSvc;
	Connection::Pointer _connection;

	State _state;

	std::string _myName, _peerName;
	std::string _key, _sentChallenge;
	std::unique_ptr<CipherConfig> _sendCipher, _recvCipher;

	AssetMap _assetMap;
	std::map<int, Asset::Handle> _requestIdMap;
	CachedAllocator<Asset::Handle> _handleAllocator;
	CachedAllocator<int> _rpcIdAllocator;

	uint8_t _protoVersion;
	size_t _bytesAllocated;
public:
	typedef std::shared_ptr<Client> Pointer;
	typedef std::weak_ptr<Client> WeakPtr;

	static Pointer create(boost::asio::io_context& ioCtx, std::string myName) {
		return Pointer(new Client(ioCtx, myName));
	}
	virtual ~Client();

	State state();
	const TimerService::Ptr& timerService();

	void setSecurity(const std::string& key, CipherType cipher);

	/**
	 * Tries to parse spec either as HOST:PORT, or as /absolute/socket/path and connect to it.
	 */
	void connect(const std::string& spec);

	void connect(boost::asio::ip::tcp::endpoint& ep);
	void connect(boost::asio::local::stream_protocol::endpoint& ep);
	void connect(Connection::Pointer newConn, const std::string& expectedPeer="");
	void hookup(bithorde::Connection::Pointer newConn);

	void close();

	bool isConnected();
	const std::string& peerName();
	const AssetMap& clientAssets() const;

	bool bind(ReadAsset & asset);
	bool bind(ReadAsset & asset, int timeout_ms);
	bool bind(bithorde::ReadAsset& asset, const bithorde::RouteTrace& requesters);
	bool bind(bithorde::ReadAsset& asset, int timeout_ms, const bithorde::RouteTrace& requesters);
	bool bind(UploadAsset & asset, int timeout_ms = 0);

	bool sendMessage(bithorde::Connection::MessageType type, const google::protobuf::Message& msg, const bithorde::Message::Deadline& expires=Message::NEVER, bool prioritized=false);

	void allocateBytes(size_t bytes);
	void freeBytes(size_t bytes);
	size_t bytesAllocated() const;

	/**
	 * Signal to indicate authentication has been performed.
	 * the second argument is the peerName. Empty peerName means authentication failed.
	 */
	boost::signals2::signal<void (Client&, const std::string&)> authenticated;
	boost::signals2::signal<void ()> writable;
	boost::signals2::signal<void ()> disconnected;

	ConnectionStats::Ptr stats;
	InertialValue assetResponseTime;

protected:
	Client(boost::asio::io_context& ioCtx, std::string myName);

	void sayHello();

	virtual void onDisconnected();
	void onIncomingMessage( bithorde::Connection::MessageType type, const google::protobuf::Message& msg );

	virtual void onMessage(const std::shared_ptr< MessageContext<bithorde::HandShake> >& msgCtx);
	virtual void onMessage(const std::shared_ptr< MessageContext<bithorde::BindRead> >& msgCtx);
	virtual void onMessage(const std::shared_ptr< MessageContext<bithorde::AssetStatus> >& msgCtx);
	virtual void onMessage(const std::shared_ptr< MessageContext<bithorde::Read::Request> >& msgCtx);
	virtual void onMessage(const std::shared_ptr< MessageContext<bithorde::Read::Response> >& msgCtx);
	virtual void onMessage(const std::shared_ptr< MessageContext<bithorde::BindWrite > >& msgCtx );
	virtual void onMessage(const std::shared_ptr< MessageContext<bithorde::DataSegment> >& msgCtx);
	virtual void onMessage(const std::shared_ptr< MessageContext<bithorde::HandShakeConfirmed> >& msgCtx);
	virtual void onMessage(const std::shared_ptr< MessageContext<bithorde::Ping> >& msgCtx);

	virtual void addStateFlag(State s);
	virtual void setAuthenticated(const std::string peerName);
private:
	bool release(Asset & a);
	void trackAllocation(ssize_t change);

	boost::signals2::scoped_connection _messageConnection;
	boost::signals2::scoped_connection _writableConnection;
	boost::signals2::scoped_connection _disconnectedConnection;

	bool informBound(const bithorde::AssetBinding& asset, int timeout_ms);
	int allocRPCRequest(Asset::Handle asset);
	void releaseRPCRequest(int reqId);
};

template <typename T>
class MessageContext {
	const Client::Pointer _client;
	const T _msg;
public:
	typedef std::shared_ptr< MessageContext<T> > Ptr;

	MessageContext(const Client::Pointer& client, const T& msg) :
		_client ( client ), _msg(msg)
	{
		_client->allocateBytes(_msg.ByteSize());
	}

	~MessageContext() {
		_client->freeBytes(_msg.ByteSize());
	}

	const T& message() const {
		return _msg;
	}

	const std::shared_ptr<Client>& client() const {
		return _client;
	}

	operator T() {
		return _msg;
	}
};

}

#endif // BITHORDE_CLIENT_H
