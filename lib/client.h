#ifndef CLIENT_H
#define CLIENT_H

#include <map>
#include <string>

#include <Poco/BasicEvent.h>
#include <Poco/EventArgs.h>

#include "asset.h"
#include "connection.h"
#include "allocator.h"

class Client
{
	Connection * _connection;

	std::string _myName;
	std::string _peerName;

	std::map<Asset::Handle, Asset*> _assetMap;
	std::map<int, Asset::Handle> _requestIdMap;
	CachedAllocator<Asset::Handle> _handleAllocator;
	CachedAllocator<int> _rpcIdAllocator;

	uint8_t _protoVersion;
public:
	explicit Client(Connection & conn, std::string myName);
	~Client();

	void bindRead(ReadAsset & asset);
	void bindWrite(UploadAsset & asset);

	bool sendMessage(Connection::MessageType type, const ::google::protobuf::Message & msg);

	Poco::BasicEvent<std::string> authenticated;
	Poco::BasicEvent<Poco::EventArgs> sent;

protected:
	void sayHello();

	void onDisconnected(Poco::EventArgs&);
	void onIncomingMessage(Connection::Message&);
	void onSent(Poco::EventArgs&);

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
	void release(Asset & a);

	int allocRPCRequest(Asset::Handle asset);
	void releaseRPCRequest(int reqId);
};

#endif // CLIENT_H
