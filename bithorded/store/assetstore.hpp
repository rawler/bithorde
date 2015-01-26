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


#ifndef BITHORDED_STORE_ASSETSTORE_HPP
#define BITHORDED_STORE_ASSETSTORE_HPP

#include <boost/filesystem/path.hpp>
#include <boost/filesystem/operations.hpp>

#include "assetindex.hpp"
#include "../../lib/hashes.h"
#include "../lib/assetsessions.hpp"
#include "../server/asset.hpp"

namespace bithorded {
	namespace management {
		struct InfoList;
	}

	namespace store {

class StoredAsset;

class AssetStore : public AssetSessions
{
	boost::filesystem::path _baseFolder;
	boost::filesystem::path _assetsFolder;
	boost::filesystem::path _tigerFolder;
public:
	AssetStore(const boost::filesystem::path& baseDir);

	virtual void inspect(management::InfoList& target) const;

	const boost::filesystem::path& assetsFolder();

	void openOrCreate();

	boost::filesystem::path newAsset();

	void update_asset(const BitHordeIds& ids, const boost::shared_ptr<StoredAsset>& asset);

	/**
	 * Calculates used store-size. Can be smaller than the sum of the file-sizes due to sparse allocation
	 */
	uint64_t size() const;

	/**
	 * Returns the "full" size of the asset, that is the size of the asset and it's metadata
	 */
	uint64_t assetFullSize(const boost::filesystem::path& path) const;

	uint64_t removeAsset(const std::string& assetId) noexcept;
	uint64_t removeAsset(const boost::filesystem::path& assetPath) noexcept;
protected:
    AssetIndex _index;
    virtual void loadIndex();

    virtual IAsset::Ptr openAsset(const bithorde::BindRead& req);
	virtual IAsset::Ptr openAsset(const boost::filesystem::path& assetPath) = 0;

private:
	void unlink(const boost::filesystem::path& linkPath) noexcept;
};
} }

#endif // BITHORDED_STORE_ASSETSTORE_HPP
