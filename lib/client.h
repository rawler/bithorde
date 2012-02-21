#ifndef CLIENT_H
#define CLIENT_H

#include <map>
#include <string>

#include <boost/bind.hpp>
#include <boost/make_shared.hpp>
#include <boost/signal.hpp>

#include "asset.h"
#include "connection.h"
#include "allocator.h"

class Client
	: public boost::signals::trackable, public boost::enable_shared_from_this<Client>
{
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

	static Pointer create(Connection::Pointer conn, std::string myName) {
		return Pointer(new Client(conn, myName));
	}

	bool bind(ReadAsset & asset);
	bool bind(UploadAsset & asset);

	bool sendMessage(Connection::MessageType type, const ::google::protobuf::Message & msg);

	boost::signal<void (std::string&)> authenticated;
	boost::signal<void ()> writable;

protected:
	Client(Connection::Pointer conn, std::string myName);

	void sayHello();

	void onDisconnected();
	void onIncomingMessage(Connection::MessageType type, ::google::protobuf::Message& msg);

	void onMessage(const bithorde::HandShake & msg);
	void onMessage(const bithorde::BindRead & msg);
	void onMessage(const bithorde::AssetStatus & msg);
	void onMessage(const bithorde::Read::Request & msg);
	void onMessage(const bithorde::Read::Response & msg);
	void onMessage(const bithorde::BindWrite & msg);
	void onMessage(const bithorde::DataSegment & msg);
	void onMessage(const bithorde::HandShakeConfirmed & msg);
	void onMessage(const bithorde::Ping & msg);

private:
	friend class Asset;
	friend class ReadAsset;
	bool release(Asset & a);

	int allocRPCRequest(Asset::Handle asset);
	void releaseRPCRequest(int reqId);
};

#endif // CLIENT_H
