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


#ifndef BITHORDED_CACHE_MANAGER_HPP
#define BITHORDED_CACHE_MANAGER_HPP

#include "asset.hpp"
#include "../lib/management.hpp"
#include "../store/assetstore.hpp"

namespace bithorded { namespace cache {

class CacheManager : private bithorded::store::AssetStore, public bithorded::management::DescriptiveDirectory
{
	boost::filesystem::path _baseDir;
	GrandCentralDispatch& _gcd;
	bithorded::IAssetSource& _router;

	uintmax_t _maxSize;
public:
	CacheManager(GrandCentralDispatch& gcd, bithorded::IAssetSource& router, const boost::filesystem::path& baseDir, intmax_t size);

	virtual void describe(management::Info& target) const;
	virtual void inspect(management::InfoList& target) const;

	bool enabled() const { return !_baseDir.empty(); }

	/**
	 * Add an asset to the idx, allocating space for
	 * the status of the asset will be updated to reflect it.
	 *
	 * If function returns true, /handler/ will be called on a thread running ioSvc.run()
	 *
	 * @returns a valid asset if file is within acceptable path, NULL otherwise
	 */
	CachedAsset::Ptr prepareUpload(uint64_t size);

	/**
	 * Version of prepareUpload which also links up the given ids to it.
	 */
	CachedAsset::Ptr prepareUpload(uint64_t size, const BitHordeIds& ids);

	/**
	 * Finds an asset by bithorde HashId. (Only the tiger-hash is actually used)
	 */
	UpstreamRequestBinding::Ptr findAsset(const bithorde::BindRead& req);
protected:
	/**
	 * Finds an asset by bithorde HashId. (Only the tiger-hash is actually used)
	 */
	IAsset::Ptr openAsset(const boost::filesystem::path& assetPath);

	virtual IAsset::Ptr openAsset(const bithorde::BindRead& req);

private:
	bool makeRoom(uint64_t size);
	void linkAsset(bithorded::cache::CachedAsset::WeakPtr asset_);
	/**
	 * Figures out which tiger-id hasn't been accessed recently.
	 */
	boost::filesystem::path pickLooser();
};
} }

#endif // BITHORDED_CACHE_STORE_HPP
