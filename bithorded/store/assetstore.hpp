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

#include "../../lib/hashes.h"
#include "../lib/assetsessions.hpp"
#include "../server/asset.hpp"

namespace bithorded { namespace store {

class StoredAsset;

class AssetStore : public AssetSessions
{
	boost::filesystem::path _assetsFolder;
	boost::filesystem::path _tigerFolder;
public:
	AssetStore(const boost::filesystem::path& baseDir);

	void openOrCreate();

	boost::filesystem::path newAssetDir();

	void link(const BitHordeIds& ids, const boost::shared_ptr<StoredAsset>& asset);

	boost::filesystem::path resolveIds(const BitHordeIds& ids);

	/**
	 * Shared code for locating assets
	 */
	IAsset::Ptr findAsset(const BitHordeIds& ids);

	/**
	 * Returns iterator allowing iterating over the assets in the store.
	 */
	boost::filesystem::directory_iterator assetIterator();

	/**
	 * Calculates used store-size. Can be smaller than the sum of the file-sizes due to sparse allocation
	 */
	uintmax_t size();

	/**
	 * Returns the "full" size of the asset, that is the size of the asset and it's metadata
	 */
	uintmax_t assetFullSize(const boost::filesystem::path& path);

	static void removeAsset(const boost::filesystem::path& assetPath) noexcept;
	static void unlink(const boost::filesystem::path& linkPath) noexcept;
	static void unlinkAndRemove(const boost::filesystem::path& linkPath) noexcept;
	void unlinkAndRemove(const BitHordeIds& ids) noexcept;

protected:
    virtual IAsset::Ptr openAsset(const bithorde::BindRead& req);
	virtual IAsset::Ptr openAsset(const boost::filesystem::path& assetPath) = 0;
};
} }

#endif // BITHORDED_STORE_ASSETSTORE_HPP
