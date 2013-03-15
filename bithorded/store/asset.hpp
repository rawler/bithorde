/*
    Copyright 2012 Ulrik Mikaelsson <email>

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

#include "assetmeta.hpp"
#include "../../lib/hashes.h"
#include "../lib/randomaccessfile.hpp"
#include "../server/asset.hpp"

namespace bithorded { namespace store {

typedef HashTree<TigerNode, AssetMeta> Hasher;

class StoredAsset : public IAsset {
protected:
	const boost::filesystem::path _assetFolder;
	boost::filesystem::path _metaFolder;
	RandomAccessFile _file;
	AssetMeta _metaStore;
	Hasher _hasher;
public:
	typedef typename boost::shared_ptr<StoredAsset> Ptr;

	/**
	 * All writes must be aligned on this BLOCKSIZE, or the data might be trimmed in the ends.
	 */
	const static int BLOCKSIZE = Hasher::BLOCKSIZE;

	StoredAsset(const boost::filesystem::path& metaFolder);
	StoredAsset(const boost::filesystem::path& metaFolder, uint64_t size);

	/**
	 * Will read up to /size/ bytes from underlying file, and send to callback.
     * TODO: refactor into passing along single AsyncRead-message.
	 */
	virtual void async_read(uint64_t offset, size_t& size, uint32_t timeout, ReadCallback cb);

	/**
	 * Returns the amount readable, starting at /offset/, and up to size.
	 *
	 * @return the amount of data available, or null if no data can be read
	 */
	virtual size_t can_read(uint64_t offset, size_t size);

	/**
	 * Get the path to the folder containing file data + metadata
	 */
	boost::filesystem::path folder();

	/**
	 * Fills ids with the ids of this asset.
	 */
	virtual bool getIds(BitHordeIds& ids) const;

	/**
	 * Is the root hash known yet?
	 */
	bool hasRootHash();

	/**
	 * Notify that given range of the file is available for hashing. Should respect BLOCKSIZE
	 */
	void notifyValidRange(uint64_t offset, uint64_t size);

	/**
	 * The size of the asset, in bytes
	 */
	virtual uint64_t size();

	/**
	 * Checks current status, possibly changing it if necessary
	 */
	void updateStatus();

private:
	void updateHash(uint64_t offset, uint64_t end);
};

}}

#endif // BITHORDED_STORE_ASSET_HPP
