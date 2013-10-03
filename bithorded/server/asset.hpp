/*
    Copyright 2012 <copyright holder> <email>

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

#include <boost/shared_ptr.hpp>
#include <boost/function.hpp>
#include <boost/signals2/signal.hpp>
#include <unordered_set>

#include <lib/hashes.h>
#include <lib/types.h>
#include "../lib/management.hpp"

namespace bithorded
{

class IAsset;
class UpstreamRequestBinding;

class AssetBinding {
	boost::shared_ptr<UpstreamRequestBinding> _ptr;
	bithorde::RouteTrace _requesters;
public:
	AssetBinding();
	AssetBinding(const AssetBinding& other);
	virtual ~AssetBinding();

	bool bind(const bithorde::RouteTrace& requesters);
	bool bind(const boost::shared_ptr< bithorded::UpstreamRequestBinding >& asset, const bithorde::RouteTrace& requesters);
	void reset();

	AssetBinding& operator=(const AssetBinding& other);
	IAsset & operator*() const;
	IAsset* operator->() const;
	IAsset* get() const;
	explicit operator bool() const;

	const boost::shared_ptr< IAsset >& shared() const;
	boost::weak_ptr< IAsset > weak() const;

	const bithorde::RouteTrace& requesters() const { return _requesters; }
};

bool operator==(const bithorded::AssetBinding& a, const boost::shared_ptr< bithorded::IAsset >& b);
bool operator!=(const bithorded::AssetBinding& a, const boost::shared_ptr< bithorded::IAsset >& b);

struct AssetRequestParameters {
	std::unordered_set<uint64_t> requesters;

	bool operator!=(const AssetRequestParameters& other);
};

class UpstreamRequestBinding : boost::noncopyable {
	boost::shared_ptr<IAsset> _ptr;
	AssetRequestParameters _parameters;
	std::unordered_set<const AssetBinding*> _downstreams;
public:
	typedef boost::shared_ptr<UpstreamRequestBinding> Ptr;
	static UpstreamRequestBinding::Ptr NONE;

	UpstreamRequestBinding(boost::shared_ptr<IAsset> asset);

	virtual bool bindDownstream(const AssetBinding* binding);
	virtual void unbindDownstream(const bithorded::AssetBinding* binding);

	const boost::shared_ptr< IAsset >& shared();
	boost::weak_ptr<IAsset> weaken();

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
	typedef boost::function<void(int64_t offset, const std::string& data)> ReadCallback;

	IAsset();

	bithorde::Status status;
	boost::signals2::signal<void(const bithorde::Status&)> statusChange;

	typedef boost::shared_ptr<IAsset> Ptr;
	typedef boost::weak_ptr<IAsset> WeakPtr;
	// Empty dummy Asset::Ptr, for cases when a null Ptr& is needed.
	static IAsset::Ptr NONE;

	virtual void async_read(uint64_t offset, size_t& size, uint32_t timeout, ReadCallback cb) = 0;
	virtual uint64_t size() = 0;

	/**
	 * The 64-bit random id generated for this node in this session of the asset.
	 */
	uint64_t sessionId() const { return _sessionId; }

	/**
	 * A set of ids for serving nodes in this session of the asset. Includes sessionId()
	 */
	virtual std::unordered_set<uint64_t> servers() const;

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
	virtual bool getIds(BitHordeIds& ids) const = 0;

	virtual void describe(management::Info& target) const;

protected:
	void setStatus(bithorde::Status newStatus);
};

class IAssetStore
{
	virtual boost::shared_ptr<IAsset> findAsset(const BitHordeIds& ids) = 0;
};

}

#endif // BITHORDED_ASSET_HPP
