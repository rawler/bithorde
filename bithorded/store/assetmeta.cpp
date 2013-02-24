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

#include <boost/filesystem.hpp>
#include <netinet/in.h>

using namespace std;
using namespace bithorded::store;

const static size_t MAP_PAGE = 1024*1024;

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

AssetMeta::AssetMeta(const boost::filesystem::path& path, uint leafBlocks)
	: _path(path), _fp(path.string()), _f()
{
	_fp.flags = io::mapped_file::mapmode::readwrite;
	_fp.offset = 0;
	_fp.length = MAP_PAGE;

	_leafBlocks = leafBlocks;
	_nodes_offset = sizeof(Header);
	_file_size = _nodes_offset + treesize(leafBlocks)*sizeof(TigerNode);

	auto status = fs::status(path);
	uint64_t size;

	if (fs::exists(status)) {
		size = fs::file_size(path);
	} else {
		size = 0;
		_fp.new_file_size = _file_size;
	}

	_slice_size = std::min(_file_size, (uint64_t)MAP_PAGE);
	_f.open(_fp);
	Header* hdr = (Header*) _f.data();
	if (size > 0) {
		if (hdr->format != 0x01)
			throw ios_base::failure("Unknown format of file");
		if (hdr->leafBlocks() != _leafBlocks)
			throw ios_base::failure("Mismatching number of blocks in file");
		if (size != _file_size)
			throw ios_base::failure("Existing file had wrong size");
	} else {
		hdr->format = 0x01;
		hdr->leafBlocks(_leafBlocks);
		_fp.new_file_size = 0;
	}
}

AssetMeta::NodePtr AssetMeta::operator[](const size_t offset)
{
	int64_t f_offset = _nodes_offset + offset*sizeof(TigerNode);
	if (f_offset < _fp.offset)
		repage(f_offset);
	else if (f_offset + sizeof(TigerNode) > _fp.offset + _slice_size)
		repage(f_offset);
	uint64_t rel_offset = f_offset - _fp.offset;
	return (TigerNode*)(_f.data()+rel_offset);
}

void AssetMeta::repage(uint64_t offset)
{
	int physpagesize = getpagesize();

	int64_t pageStart = offset - (MAP_PAGE / 4);
	if ((uint64_t)(pageStart + MAP_PAGE) > _file_size)
		pageStart = _file_size - (MAP_PAGE - physpagesize);

	// Align on correct pages
	pageStart = pageStart & ~(physpagesize-1);

	if (pageStart < 0)
		pageStart = 0;
	_fp.offset = pageStart;
	_f.close();
	_f.open(_fp);
	_slice_size = std::min(_file_size - pageStart, (uint64_t)MAP_PAGE);
}

size_t AssetMeta::size()
{
	return (_file_size - _nodes_offset) / sizeof(TigerNode);
}

const boost::filesystem::path& AssetMeta::path() const
{
	return _path;
}
