#ifndef BITHORDE_ASSET_H
#define BITHORDE_ASSET_H

#include <inttypes.h>
#include <map>
#include <utility>
#include <vector>
#include <unordered_set>

#include <boost/asio/deadline_timer.hpp>
#include <boost/filesystem/path.hpp>
#include <boost/signals2.hpp>

#include "bithorde.pb.h"
#include "counter.h"
#include "hashes.h"
#include "types.h"

namespace bithorde {

class Client;
class AssetBinding;
class IBuffer;

template <typename T>
class MessageContext;

static boost::arg<1> ASSET_ARG_STATUS;

/**
 * Tests if any of the ids in a matches any of the ids in b
 */
bool idsOverlap(const bithorde::Ids& a, const bithorde::Ids& b);

class Asset
{
	friend class AssetBinding;
	friend class Client;
public:
	typedef std::shared_ptr<Client> ClientPointer;
	typedef int Handle;

	explicit Asset(const ClientPointer& client);
	virtual ~Asset();

	const ClientPointer& client();
	boost::asio::io_context& ioCtx();
	bool isBound();
	Handle handle();
	std::string label();
	uint64_t size();

	const std::unordered_set<uint64_t>& servers();

	typedef boost::signals2::signal<void (const bithorde::AssetStatus&)> StatusSignal;
	typedef boost::signals2::signal<void ()> VoidSignal;
	VoidSignal closed;
	StatusSignal statusUpdate;
	bithorde::Status status;

	void close();
protected:
	ClientPointer _client;
	boost::asio::io_context& _ioCtx;
	Handle _handle;
	int64_t _size;
	std::unordered_set<uint64_t> _servers;

	virtual void handleMessage(const bithorde::AssetStatus &msg);
	virtual void handleMessage( const std::shared_ptr< MessageContext< bithorde::Read::Response > >& msg ) = 0;
};

static boost::arg<1> ASSET_ARG_OFFSET;
static boost::arg<2> ASSET_ARG_DATA;
static boost::arg<3> ASSET_ARG_TAG;

class ReadAsset;
class ReadRequestContext : boost::noncopyable, public bithorde::Read_Request, public std::enable_shared_from_this<ReadRequestContext> {
	ReadAsset* _asset;
	Asset::ClientPointer _client;
	boost::asio::deadline_timer _timer;
	boost::posix_time::ptime _requested_at;
public:
	typedef std::shared_ptr<ReadRequestContext> Ptr;
	ReadRequestContext(bithorde::ReadAsset* asset, uint64_t offset, std::size_t size, int32_t timeout);
	virtual ~ReadRequestContext();

	void armTimer(int32_t timeout);
	void callback( const std::shared_ptr< bithorde::MessageContext< bithorde::Read::Response > >& msgCtx );
	void timer_callback(const boost::system::error_code& error);
	void cancel();
};

class ReadAsset : public Asset, boost::noncopyable
{
	friend class ReadRequestContext;
public:
	typedef std::shared_ptr<Client> ClientPointer;
	typedef std::shared_ptr<ReadAsset> Ptr;
	typedef uint64_t off_t;

	typedef std::pair<bithorde::HashType, std::string> Identifier;

	explicit ReadAsset(const bithorde::ReadAsset::ClientPointer& client, const bithorde::Ids& requestIds);
	virtual ~ReadAsset();
	void cancelRequests();

	int aSyncRead(off_t offset, ssize_t size, int32_t timeout=10000);
	const bithorde::Ids & requestIds() const;
	const bithorde::Ids & confirmedIds() const;

	typedef boost::signals2::signal<void (off_t offset, const std::shared_ptr<IBuffer>& data, int tag)> DataSignal;
	DataSignal dataArrived;

	InertialValue readResponseTime;
protected:
	virtual void handleMessage(const bithorde::AssetStatus &msg);
	virtual void handleMessage( const std::shared_ptr< bithorde::MessageContext< bithorde::Read::Response > >& msgCtx );
	void clearOffset(off_t offset, uint32_t reqid);

private:
	bithorde::Ids _requestIds;
	bithorde::Ids _confirmedIds;
	typedef std::multimap<off_t, ReadRequestContext::Ptr> RequestMap;
	RequestMap _requestMap;
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
	virtual void handleMessage( const std::shared_ptr< bithorde::MessageContext< bithorde::Read::Response > >& msgCtx );
};

}

#endif // BITHORDE_ASSET_H
