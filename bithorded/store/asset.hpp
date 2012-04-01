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


#ifndef BITHORDED_ASSET_H
#define BITHORDED_ASSET_H

#include <boost/filesystem/path.hpp>
#include <boost/shared_ptr.hpp>

#include "assetmeta.hpp"

#include "../lib/hashtree.hpp"
#include "../lib/randomaccessfile.hpp"

#include "bithorde.pb.h"

namespace bithorded {

class Asset
{
public:
	typedef HashTree<TigerNode, AssetMeta> Hasher;
	typedef boost::shared_ptr<Asset> Ptr;

	/**
	 * All writes must be aligned on this BLOCKSIZE, or the data might be trimmed in the ends.
	 */
	const static int BLOCKSIZE = Hasher::BLOCKSIZE;

	Asset(const boost::filesystem::path& filePath, const boost::filesystem::path& metaPath);

	/**
	 * Will read up to /size/ bytes from underlying file, and store into a buffer.
	 *
	 * @arg size - will be filled in with the amount actually read
	 * @return a pointer to the buffer read, which may or may not be /buf/, or null on error.
	 */
	const byte* read(uint64_t offset, size_t& size, byte* buf);

	/**
	 * The size of the asset, in bytes
	 */
	uint64_t size();

	/**
	 * Returns the amount readable, starting at /offset/, and up to size.
	 *
	 * @return the amount of data available, or null if no data can be read
	 */
	size_t can_read(uint64_t offset, size_t size);

	/**
	 * Notify that given range of the file is available for hashing. Should respect BLOCKSIZE
	 */
	void notifyValidRange(uint64_t offset, uint64_t size);

	/**
	 * Writes up to /size/ from buf into asset, updating amount written in hasher
	 */
	size_t write(uint64_t offset, const void* buf, size_t size);

	/**
	 * Is the root hash known yet?
	 */
	bool hasRootHash();

	/**
	 * Writes the root hash of the asset into /buf/. Buf is assumed to have capacity for Hasher::DIGESTSIZE
	 */
	bool getIds(BitHordeIds& ids);

	/**
	 * Get the path to the file used for storing actual blocks
	 */
	boost::filesystem::path storageFile();

	/**
	 * Get the path to the file used for storing meta-info such as the hashtree
	 */
	boost::filesystem::path metaFile();
private:
	void updateHash(uint64_t offset, uint64_t end);

	RandomAccessFile _file;
	AssetMeta _metaStore;
	Hasher _hasher;
};

// Empty dummy Asset::Ptr, for cases when a null Ptr& is needed.
static Asset::Ptr ASSET_NONE;

}
#endif // BITHORDED_ASSET_H
