#ifndef ASSET_H
#define ASSET_H

#include <inttypes.h>
#include <utility>
#include <vector>

#include <Poco/BasicEvent.h>
#include <Poco/EventArgs.h>

#include "bithorde.pb.h"
#include "types.h"

class Client;

class Asset
{
public:
	typedef int Handle;
	explicit Asset(Client * client);
	virtual ~Asset();

	bool isBound();
	uint64_t size();

	Poco::BasicEvent<Poco::EventArgs> closed();
	Poco::BasicEvent<const bithorde::AssetStatus> statusUpdate;

	void close();
protected:
	Client * _client;
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

	explicit ReadAsset(Client * client, IdList requestIds);

	int aSyncRead(uint64_t offset, ssize_t size);
	IdList & requestIds();

	struct Segment {
		uint64_t offset;
		ByteArray data;
		int tag;
		Segment(uint64_t offset, ByteArray data, int tag) :
			offset(offset),
			data(data),
			tag(tag) {}
	};
	Poco::BasicEvent<const Segment> dataArrived;

protected:
	virtual void handleMessage(const bithorde::AssetStatus &msg);
	virtual void handleMessage(const bithorde::Read::Response &msg);

private:
	IdList _requestIds;
};

class UploadAsset : public Asset
{
public:
    explicit UploadAsset(Client * client, uint64_t size);

    bool tryWrite(uint64_t offset, byte* data, size_t amount);

protected:
    virtual void handleMessage(const bithorde::Read::Response &msg);
};

#endif // ASSET_H
