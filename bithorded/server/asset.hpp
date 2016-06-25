/*
    Copyright 2016 Ulrik Mikaelsson <ulrik.mikaelsson@gmail.com>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
*/


#ifndef BITHORDED_ASSET_HPP
#define BITHORDED_ASSET_HPP

#include <boost/signals2/connection.hpp>
#include <unordered_set>

#include <lib/hashes.h>
#include <lib/types.h>
#include <lib/protocolmessages.hpp>
#include "../lib/management.hpp"
#include "../lib/subscribable.hpp"

namespace bithorde {
class IBuffer;
}

namespace bithorded
{

class Client;

class IAsset;
class UpstreamRequestBinding;

class AssetBinding {
	Client* _client; // Client owns us, so should always be valid.
	std::shared_ptr<UpstreamRequestBinding> _ptr;
	BitHordeIds _assetIds;
	bithorde::RouteTrace _requesters;
	boost::posix_time::ptime _deadline;
	boost::signals2::connection _statusConnection;
public:
	typedef std::function<void (const std::shared_ptr< IAsset >&, const bithorde::AssetStatus&)> StatusFunc;

	AssetBinding();
	AssetBinding(const AssetBinding& other);
	virtual ~AssetBinding();

	void setClient(const std::shared_ptr<Client>& client);
	Client* client() const;

	bool bind( const bithorde::RouteTrace& requesters );
	bool bind( const std::shared_ptr< bithorded::UpstreamRequestBinding >& asset, const BitHordeIds& assetIds, const bithorde::RouteTrace& requesters, const boost::posix_time::ptime& deadline );
	bool bind( const std::shared_ptr< bithorded::UpstreamRequestBinding >& asset, const BitHordeIds& assetIds, const bithorde::RouteTrace& requesters, const boost::posix_time::ptime& deadline, StatusFunc statusUpdate );
	void reset();

	AssetBinding& operator=(const AssetBinding& other);
	IAsset & operator*() const;
	IAsset* operator->() const;
	IAsset* get() const;
	explicit operator bool() const;

	const std::shared_ptr< IAsset >& shared() const;
	std::weak_ptr< IAsset > weak() const;

	const BitHordeIds& assetIds() const { return _assetIds; };
	const bithorde::RouteTrace& requesters() const { return _requesters; }

	const boost::posix_time::ptime& deadline() const { return _deadline; }
	void clearDeadline();
};

bool operator==(const bithorded::AssetBinding& a, const std::shared_ptr< bithorded::IAsset >& b);
bool operator!=(const bithorded::AssetBinding& a, const std::shared_ptr< bithorded::IAsset >& b);

struct AssetRequestParameters {
	std::unordered_set<uint64_t> requesters;
	std::unordered_set<Client*> requesterClients;
	boost::posix_time::ptime deadline;

	bool isRequester(const std::shared_ptr<Client>& client) const;
	bool operator!=(const AssetRequestParameters& other) const;
};

class UpstreamRequestBinding : boost::noncopyable {
	std::shared_ptr<IAsset> _ptr;
	AssetRequestParameters _parameters;
	std::unordered_set<const AssetBinding*> _downstreams;
public:
	typedef std::shared_ptr<UpstreamRequestBinding> Ptr;
	static UpstreamRequestBinding::Ptr NONE;

	UpstreamRequestBinding(std::shared_ptr<IAsset> asset);

	virtual bool bindDownstream(const AssetBinding* binding);
	virtual void unbindDownstream(const bithorded::AssetBinding* binding);

	const std::shared_ptr< IAsset >& shared();
	std::weak_ptr<IAsset> weaken();

	IAsset* get() const;
	IAsset* operator->() const;
	IAsset& operator*() const;
private:
	void rebuild();
};

class IAsset : public management::DescriptiveDirectory
{
	uint64_t _sessionId;
public:
	typedef boost::function<void(int64_t offset, const std::shared_ptr<bithorde::IBuffer>& data)> ReadCallback;

	IAsset();

	Subscribable<bithorde::AssetStatus> status;

	typedef std::shared_ptr<IAsset> Ptr;
	typedef std::weak_ptr<IAsset> WeakPtr;
	// Empty dummy Asset::Ptr, for cases when a null Ptr& is needed.
	static IAsset::Ptr NONE;

	virtual void async_read(uint64_t offset, size_t size, uint32_t timeout, ReadCallback cb) = 0;
	virtual uint64_t size() = 0;

	/**
	 * The 64-bit random id generated for this node in this session of the asset.
	 */
	uint64_t sessionId() const { return _sessionId; }

	/**
	 * Current AssetRequestParameters were updated for this session
	 */
	virtual void apply(const AssetRequestParameters& old_parameters, const AssetRequestParameters& new_parameters) = 0;

	/**
	 * Valid parameters
	 * offset - 0 to size() - size
	 * size - 1 to size()
	 */
	virtual size_t can_read(uint64_t offset, size_t size) = 0;

	virtual void describe(management::Info& target) const;
};

class IAssetSource
{
public:
	virtual UpstreamRequestBinding::Ptr findAsset(const bithorde::BindRead& req) = 0;
};

}

#endif // BITHORDED_ASSET_HPP
