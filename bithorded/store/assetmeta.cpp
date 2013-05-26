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

#include "assetmeta.hpp"

#include <algorithm>
#include <sstream>

#include <boost/filesystem.hpp>
#include <boost/smart_ptr/make_shared.hpp>
#include <netinet/in.h>

using namespace std;
using namespace bithorded::store;

const static size_t MAP_PAGE = 128*1024;

namespace io = boost::iostreams;
namespace fs = boost::filesystem;

#pragma pack(push, 1)
struct Header {
	uint8_t format;
	uint32_t _leafBlocks;

	uint32_t leafBlocks() {
		return ntohl(_leafBlocks);
	}

	uint32_t leafBlocks(uint32_t val) {
		_leafBlocks = htonl(val);
		return val;
	}
};
#pragma pack(pop)

bithorded::store::TigerNode::TigerNode(AssetMeta& metaFile, size_t offset) :
	TigerBaseNode(metaFile.read(offset)),
	_metaFile(metaFile),
	_offset(offset)
{

}

bithorded::store::TigerNode::~TigerNode()
{
	_metaFile.write(_offset, *this);
}

AssetMeta::AssetMeta(const boost::filesystem::path& path, uint32_t leafBlocks)
	: _leafBlocks(leafBlocks), _nodes_offset(sizeof(Header))
{
	uint64_t expectedSize = _nodes_offset + treesize(leafBlocks)*sizeof(TigerBaseNode);
	bool wasPresent = fs::exists(path);
	_file.open(path, RandomAccessFile::READWRITE, expectedSize);

	Header hdr;
	if (wasPresent) {
		auto hdr_size = sizeof(Header);
		_file.read(0, hdr_size, (byte*)&hdr);
		if (hdr_size != sizeof(Header))
			throw ios_base::failure("Failed to read header from "+path.string());
		if (hdr.format != 0x01)
			throw ios_base::failure("Unknown format of file "+path.string());
		if (hdr.leafBlocks() != _leafBlocks)
			throw ios_base::failure("Mismatching number of blocks in file"+path.string());
	} else {
		hdr.format = 0x01;
		hdr.leafBlocks(_leafBlocks);
		if (_file.write(0, &hdr, sizeof(Header)) != sizeof(Header))
			throw ios_base::failure("Failed to write header to "+path.string());
	}
}

AssetMeta::NodePtr AssetMeta::operator[](const size_t offset)
{
	if (auto node = _nodeMap[offset]) {
		return node;
	} else {
		auto res = boost::make_shared<TigerNode>(*this, offset);
		_nodeMap.set(offset, res);
		return res;
	}
}

size_t AssetMeta::size()
{
	return (_file.size() - _nodes_offset) / sizeof(TigerBaseNode);
}

TigerBaseNode AssetMeta::read(size_t offset)
{
	uint64_t f_offset = _nodes_offset + offset*sizeof(TigerBaseNode);
	TigerBaseNode res;
	size_t node_size = sizeof(TigerBaseNode);
	_file.read(f_offset, node_size, (byte*)&res);
	if (node_size != sizeof(TigerBaseNode)) {
		ostringstream buf;
		buf << "Failed reading node at offset " << offset;
		throw ios_base::failure(buf.str());
	}
	return res;
}

void AssetMeta::write(size_t offset, const TigerBaseNode& node)
{
	uint64_t f_offset = _nodes_offset + offset*sizeof(TigerBaseNode);
	auto written = _file.write(f_offset, (byte*)&node, sizeof(TigerBaseNode));
	if (written != sizeof(TigerBaseNode)) {
		ostringstream buf;
		buf << "Failed writing node at offset " << offset;
		throw ios_base::failure(buf.str());
	}
}
