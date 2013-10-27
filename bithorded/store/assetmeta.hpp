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


#ifndef BITHORDED_ASSETMETA_H
#define BITHORDED_ASSETMETA_H

#include <boost/filesystem/path.hpp>
#include <boost/interprocess/sync/null_mutex.hpp>
#include <boost/iostreams/device/mapped_file.hpp>
#include <boost/noncopyable.hpp>

#include <crypto++/tiger.h>

#include "bithorded/lib/hashtree.hpp"
#include "bithorded/lib/randomaccessfile.hpp"
#include <bithorded/lib/weakmap.hpp>
#include "lib/types.h"

namespace bithorded { namespace store {

typedef HashNode<CryptoPP::Tiger> TigerBaseNode;

class AssetMeta;

class TigerNode : public TigerBaseNode, private boost::noncopyable {
	AssetMeta& _metaFile;
	size_t _offset;
	TigerBaseNode _unmodified;
public:
	TigerNode(AssetMeta& metaFile, size_t offset);
	virtual ~TigerNode();
};

class AssetMeta {
	RandomAccessFile _file;
	WeakMap<std::size_t, TigerNode, boost::interprocess::null_mutex> _nodeMap;

	size_t _leafBlocks;
	size_t _nodes_offset;
public:
	typedef typename boost::shared_ptr<TigerNode> NodePtr;
	AssetMeta(const boost::filesystem::path& path, uint32_t leafBlocks);

	NodePtr operator[](const std::size_t offset);
	size_t size();

	TigerBaseNode read(size_t offset);
	void write(size_t offset, const TigerBaseNode& node);
};

} }
#endif // BITHORDED_ASSETMETA_H
