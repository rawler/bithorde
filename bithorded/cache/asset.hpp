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

#ifndef BITHORDED_CACHE_ASSET_HPP
#define BITHORDED_CACHE_ASSET_HPP

#include <boost/filesystem/path.hpp>

#include "../lib/hashtree.hpp"
#include "../server/asset.hpp"
#include "../store/asset.hpp"
#include "../router/asset.hpp"

namespace bithorded {
	namespace cache {

class CacheManager;

class CachedAsset : public store::StoredAsset
{
public:
	typedef boost::shared_ptr<CachedAsset> Ptr;
	typedef boost::weak_ptr<CachedAsset> WeakPtr;

	CachedAsset(const boost::filesystem::path& metaFolder);
	CachedAsset(const boost::filesystem::path& metaFolder, uint64_t size);

	virtual void inspect(management::InfoList& target) const;

	/**
	 * Writes up to /size/ from buf into asset, updating amount written in hasher
	 */
	size_t write(uint64_t offset, const std::string& data);
};

class CachingAsset : public IAsset, public boost::enable_shared_from_this<CachingAsset> {
	CacheManager& _manager;
	router::ForwardedAsset::Ptr _upstream;
	CachedAsset::Ptr _cached;
public:
	CachingAsset(CacheManager& mgr, bithorded::router::ForwardedAsset::Ptr upstream, bithorded::cache::CachedAsset::Ptr cached);
	virtual ~CachingAsset();

	virtual void inspect(management::InfoList& target) const;

	virtual void async_read(uint64_t offset, size_t& size, uint32_t timeout, ReadCallback cb);

	virtual bool getIds(BitHordeIds& ids) const;

	virtual size_t can_read(uint64_t offset, size_t size);

	virtual uint64_t size();

private:
	void disconnect();
	void upstreamDataArrived(ReadCallback cb, int64_t offset, const std::string& data);
	void upstreamStatusChange(bithorde::Status newStatus);
};
	}
}

#endif // BITHORDED_CACHE_ASSET_HPP
