#ifndef BITHORDE_ASSET_H
#define BITHORDE_ASSET_H

#include <inttypes.h>
#include <utility>
#include <vector>

#include <boost/bind/placeholders.hpp>
#include <boost/bind/arg.hpp>
#include <boost/filesystem/path.hpp>
#include <boost/signals2.hpp>
#include <boost/shared_ptr.hpp>

#include "hashes.h"
#include "bithorde.pb.h"
#include "types.h"

namespace bithorde {

class Client;

static boost::arg<1> ASSET_ARG_STATUS;

/**
 * Tests if any of the ids in a matches any of the ids in b
 */
bool idsOverlap(const BitHordeIds& a, const BitHordeIds& b);

class Asset
{
public:
	typedef boost::shared_ptr<Client> ClientPointer;
	typedef int Handle;

	explicit Asset(const ClientPointer& client);
	virtual ~Asset();

	bool isBound();
	uint64_t size();

	typedef boost::signals2::signal<void (const bithorde::AssetStatus&)> StatusSignal;
	typedef boost::signals2::signal<void ()> VoidSignal;
	VoidSignal closed;
	StatusSignal statusUpdate;
	bithorde::Status status;

	void close();
protected:
	ClientPointer _client;
	Handle _handle;
	int64_t _size;

	friend class Client;
	virtual void handleMessage(const bithorde::AssetStatus &msg);
	virtual void handleMessage(const bithorde::Read::Response &msg) = 0;
};

static boost::arg<1> ASSET_ARG_OFFSET;
static boost::arg<2> ASSET_ARG_DATA;
static boost::arg<3> ASSET_ARG_TAG;

class ReadAsset : public Asset, boost::noncopyable
{
public:
	typedef boost::shared_ptr<Client> ClientPointer;
	typedef boost::shared_ptr<ReadAsset> Ptr;

	typedef std::pair<bithorde::HashType, std::string> Identifier;

	explicit ReadAsset(const bithorde::ReadAsset::ClientPointer& client, const BitHordeIds& requestIds);

	int aSyncRead(uint64_t offset, ssize_t size);
	const BitHordeIds & requestIds() const;

	typedef boost::signals2::signal<void (uint64_t offset, const std::string& data, int tag)> DataSignal;
	DataSignal dataArrived;

protected:
	virtual void handleMessage(const bithorde::AssetStatus &msg);
	virtual void handleMessage(const bithorde::Read::Response &msg);

private:
	BitHordeIds _requestIds;
};

class UploadAsset : public Asset
{
	boost::filesystem::path _linkPath;
public:
	explicit UploadAsset(const ClientPointer& client, uint64_t size);
	explicit UploadAsset(const ClientPointer& client, const boost::filesystem::path& path);

	bool tryWrite(uint64_t offset, byte* data, size_t amount);
	const boost::filesystem::path& link();

protected:
	virtual void handleMessage(const bithorde::Read::Response &msg);
};

}

#endif // BITHORDE_ASSET_H
