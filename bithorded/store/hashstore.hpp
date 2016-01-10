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


#ifndef BITHORDED_HASHSTORE_HPP
#define BITHORDED_HASHSTORE_HPP

#include <boost/filesystem/path.hpp>
#include <boost/interprocess/sync/null_mutex.hpp>
#include <boost/iostreams/device/mapped_file.hpp>

#include <crypto++/tiger.h>

#include "bithorded/lib/hashtree.hpp"
#include "bithorded/lib/randomaccessfile.hpp"
#include <bithorded/lib/weakmap.hpp>
#include "lib/types.h"

namespace bithorded { namespace store {

typedef HashNode<CryptoPP::Tiger> TigerBaseNode;

class HashStore;

class TigerNode : public TigerBaseNode{
	HashStore& _metaFile;
	size_t _offset;
	TigerBaseNode _unmodified;
public:
	TigerNode(HashStore& metaFile, size_t offset);
	TigerNode( const TigerNode& ) = delete;
	virtual ~TigerNode();
};

class HashStore {
	IDataArray::Ptr _storage;
	WeakMap<std::size_t, TigerNode, boost::interprocess::null_mutex> _nodeMap;
	uint8_t _hashLevelsSkipped;
public:
	typedef TigerBaseNode Node;
	typedef typename std::shared_ptr<TigerNode> NodePtr;
	typedef std::shared_ptr<HashStore> Ptr;
	explicit HashStore(const IDataArray::Ptr& storage, uint8_t hashLevelsSkipped=0);

	NodePtr operator[](const std::size_t offset);
	size_t size() const;

	uint8_t hashLevelsSkipped() const { return _hashLevelsSkipped; }

	/**
	 * The size of the block of data for the leaves.
	 */
	size_t leafBlockSize() const { return TreeHasher< Node::HashAlgorithm >::ATOMSIZE << _hashLevelsSkipped; }

	TigerBaseNode read(size_t offset) const;
	void write(size_t offset, const TigerBaseNode& node);

	static uint64_t atoms_needed_for_content(uint64_t content_size);
	static uint64_t leaves_needed_for_atoms(uint64_t atoms, uint8_t levelsSkipped=0);
	static uint64_t leaves_needed_for_content(uint64_t content_size, uint8_t levelsSkipped=0);
	static uint64_t nodes_needed_for_atoms(uint64_t atoms, uint8_t levelsSkipped=0);
	static uint64_t nodes_needed_for_content(uint64_t content_size, uint8_t levelsSkipped=0);
	static uint64_t size_needed_for_atoms(uint64_t atoms, uint8_t levelsSkipped=0);
	static uint64_t size_needed_for_content(uint64_t content_size, uint8_t levelsSkipped=0);
};

} }
#endif // BITHORDED_HASHSTORE_HPP
