#ifndef ASSET_H
#define ASSET_H

#include <inttypes.h>
#include <utility>
#include <vector>

#include <boost/signal.hpp>
#include <boost/shared_ptr.hpp>

#include "bithorde.pb.h"
#include "types.h"

class Client;

class Asset
{
public:
	typedef boost::shared_ptr<Client> ClientPointer;
	typedef int Handle;

	explicit Asset(ClientPointer client);
	virtual ~Asset();

	bool isBound();
	uint64_t size();

	boost::signal<void ()> closed;
	boost::signal<void (const bithorde::AssetStatus&)> statusUpdate;

	void close();
protected:
	ClientPointer _client;
	Handle _handle;
	int64_t _size;

	friend class Client;
	virtual void handleMessage(const bithorde::AssetStatus &msg);
	virtual void handleMessage(const bithorde::Read::Response &msg) = 0;
};

class ReadAsset : public Asset
{
public:
	typedef std::pair<bithorde::HashType, ByteArray> Identifier;
	typedef std::vector<Identifier> IdList;

	explicit ReadAsset(ClientPointer client, ReadAsset::IdList requestIds);

	int aSyncRead(uint64_t offset, ssize_t size);
	const IdList & requestIds() const;

	boost::signal<void (uint64_t offset, ByteArray& data, int tag)> dataArrived;

protected:
	virtual void handleMessage(const bithorde::AssetStatus &msg);
	virtual void handleMessage(const bithorde::Read::Response &msg);

private:
	IdList _requestIds;
};

class UploadAsset : public Asset
{
public:
	explicit UploadAsset(ClientPointer client, uint64_t size);

	bool tryWrite(uint64_t offset, byte* data, size_t amount);

protected:
	virtual void handleMessage(const bithorde::Read::Response &msg);
};

#endif // ASSET_H
