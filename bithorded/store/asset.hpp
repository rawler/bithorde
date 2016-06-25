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


#ifndef BITHORDED_STORE_ASSET_HPP
#define BITHORDED_STORE_ASSET_HPP

#include "hashstore.hpp"
#include "../../lib/hashes.h"
#include "../lib/randomaccessfile.hpp"
#include "../server/asset.hpp"

namespace bithorded {

class GrandCentralDispatch;

namespace store {

const uint8_t DEFAULT_HASH_LEVELS_SKIPPED = 6;

typedef HashTree<HashStore> Hasher;

class StoredAsset : public IAsset, public std::enable_shared_from_this<StoredAsset> {
protected:
	GrandCentralDispatch& _gcd;
	const std::string _id;
	IDataArray::Ptr _data;
	HashStore::Ptr _hashStore;
	Hasher _hashTree;
public:
	typedef typename std::shared_ptr<StoredAsset> Ptr;

	StoredAsset(GrandCentralDispatch& gcd, const std::string& id, const HashStore::Ptr hashStore, const IDataArray::Ptr& data);

	/**
	 * Will read up to /size/ bytes from underlying file, and send to callback.
     * TODO: refactor into passing along single AsyncRead-message.
	 */
	virtual void async_read( uint64_t offset, size_t size, uint32_t timeout, IAsset::ReadCallback cb );

	/**
	 * Returns the amount readable, starting at /offset/, and up to size.
	 *
	 * @return the amount of data available, or null if no data can be read
	 */
	virtual size_t can_read(uint64_t offset, size_t size);

	/**
	 * Is the root hash known yet?
	 */
	bool hasRootHash();

	/**
	 * Notify that given range of the file is available for hashing. Should respect BLOCKSIZE
	 */
	void notifyValidRange(uint64_t offset, uint64_t size, std::function< void() > whenDone=0);

	/**
	 * Unique local ID for this asset
	 */
	const std::string& id() const;

	/**
	 * The size of the asset, in bytes
	 */
	virtual uint64_t size();

	/**
	 * Checks current status, possibly changing it if necessary
	 */
	void updateStatus();

private:
	void updateHash(uint64_t offset, uint64_t end, std::function< void() > whenDone);
};

enum FileFormatVersion {
	V1FORMAT = 0x01,
	V2CACHE = 0x02,
	V2LINKED = 0x03,
};

struct AssetMeta {
	uint8_t hashLevelsSkipped;
	uint64_t atoms;
	HashStore::Ptr hashStore;
	IDataArray::Ptr tail;
};

AssetMeta openV1AssetMeta( const boost::filesystem::path& path );
AssetMeta openV2AssetMeta( const boost::filesystem::path& path );

AssetMeta createAssetMeta( const boost::filesystem::path& path, bithorded::store::FileFormatVersion version, uint64_t dataSize, uint8_t levelsSkipped, uint64_t tailSize );

}}

#endif // BITHORDED_STORE_ASSET_HPP
