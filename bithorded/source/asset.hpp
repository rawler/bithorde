/*
    Copyright 2012 Ulrik Mikaelsson <ulrik.mikaelsson@gmail.com>

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


#ifndef BITHORDED_SOURCE_ASSET_H
#define BITHORDED_SOURCE_ASSET_H

#include <boost/filesystem/path.hpp>
#include <boost/shared_ptr.hpp>

#include "../store/assetmeta.hpp"

#include "../server/asset.hpp"
#include "../lib/hashtree.hpp"
#include "../lib/randomaccessfile.hpp"

#include "bithorde.pb.h"

namespace bithorded {
	namespace source {

class SourceAsset : public IAsset
{
public:
	typedef HashTree<TigerNode, AssetMeta> Hasher;
	typedef boost::shared_ptr<SourceAsset> Ptr;
	typedef boost::weak_ptr<SourceAsset> WeakPtr;

	/**
	 * All writes must be aligned on this BLOCKSIZE, or the data might be trimmed in the ends.
	 */
	const static int BLOCKSIZE = Hasher::BLOCKSIZE;

	SourceAsset(const boost::filesystem::path& metaFolder);

	/**
	 * Will read up to /size/ bytes from underlying file, and send to callback.
	 */
	virtual void async_read(uint64_t offset, size_t& size, ReadCallback cb);

	/**
	 * The size of the asset, in bytes
	 */
	virtual uint64_t size();

	/**
	 * Returns the amount readable, starting at /offset/, and up to size.
	 *
	 * @return the amount of data available, or null if no data can be read
	 */
	virtual size_t can_read(uint64_t offset, size_t size);

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
	virtual bool getIds(BitHordeIds& ids);

	/**
	 * Get the path to the folder containing file data + metadata
	 */
	boost::filesystem::path folder();

	/**
	 * Checks current status, possibly changing it if necessary
	 */
	void updateStatus();
private:
	void updateHash(uint64_t offset, uint64_t end);

	boost::filesystem::path _metaFolder;
	RandomAccessFile _file;
	AssetMeta _metaStore;
	Hasher _hasher;
};

	}
}
#endif // BITHORDED_SOURCE_ASSET_H
