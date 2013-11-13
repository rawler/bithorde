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

#include "hashstore.hpp"

#include "../lib/hashtree.hpp"

#include <algorithm>
#include <sstream>

#include <boost/filesystem.hpp>
#include <boost/smart_ptr/make_shared.hpp>
#include <netinet/in.h>

using namespace std;
using namespace bithorded::store;

namespace io = boost::iostreams;
namespace fs = boost::filesystem;

bithorded::store::TigerNode::TigerNode(HashStore& metaFile, size_t offset) :
	TigerBaseNode(metaFile.read(offset)),
	_metaFile(metaFile),
	_offset(offset),
	_unmodified(*this)
{
}

bithorded::store::TigerNode::~TigerNode()
{
	if (_unmodified != *static_cast<TigerBaseNode*>(this)) {
		_metaFile.write(_offset, *this);
	}
}

HashStore::HashStore( const bithorded::IDataArray::Ptr& storage )
	: _storage(storage)
{
	if (_storage->size() == 0) {
		throw ios_base::failure("Hash storage of size 0 is pointless; "+storage->describe());
	} else if (_storage->size() % sizeof(TigerBaseNode)) {
		throw ios_base::failure("Hash storage not even multiple of nodes; "+storage->describe());
	}
}

HashStore::NodePtr HashStore::operator[](const size_t offset)
{
	if (auto node = _nodeMap[offset]) {
		return node;
	} else {
		auto res = boost::make_shared<TigerNode>(*this, offset);
		_nodeMap.set(offset, res);
		return res;
	}
}

size_t HashStore::size() const
{
	return _storage->size() / sizeof(TigerBaseNode);
}

TigerBaseNode HashStore::read(size_t offset) const
{
	uint64_t f_offset = offset*sizeof(TigerBaseNode);
	TigerBaseNode res;
	auto read = _storage->read(f_offset, sizeof(TigerBaseNode), reinterpret_cast<byte*>(&res));
	if (read != sizeof(TigerBaseNode)) {
		ostringstream buf;
		buf << "Failed reading node at offset " << offset;
		throw ios_base::failure(buf.str());
	}
	return res;
}

void HashStore::write(size_t offset, const TigerBaseNode& node)
{
	uint64_t f_offset = offset*sizeof(TigerBaseNode);
	auto written = _storage->write(f_offset, reinterpret_cast<const byte*>(&node), sizeof(TigerBaseNode));
	if (written != sizeof(TigerBaseNode)) {
		ostringstream buf;
		buf << "Failed writing node at offset " << offset;
		throw ios_base::failure(buf.str());
	}
}

uint64_t HashStore::leaves_needed ( uint64_t content_size, uint8_t levelsSkipped ) {
	auto blockSize = TreeHasher<Node::HashAlgorithm>::UNITSIZE;
	auto leaves = (content_size + blockSize - 1) / blockSize;
	auto stored_leaves = leaves >> levelsSkipped;
	if ((stored_leaves >> levelsSkipped) == leaves) {
		// Exact match
		return stored_leaves;
	} else {
		// There were overflow
		return stored_leaves + 1;
	}
}

uint64_t HashStore::nodes_needed ( uint64_t content_size, uint8_t levelsSkipped ) {
	return treesize(leaves_needed(content_size, levelsSkipped));
}

uint64_t HashStore::size_needed ( uint64_t content_size, uint8_t levelsSkipped ) {
	return nodes_needed(content_size, levelsSkipped) * Node::DigestSize;
}
