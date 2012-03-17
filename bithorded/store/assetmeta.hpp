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


#ifndef ASSETMETA_H
#define ASSETMETA_H

#include <boost/filesystem/path.hpp>
#include <boost/iostreams/device/mapped_file.hpp>

#include <crypto++/tiger.h>

#include "bithorded/lib/hashtree.hpp"
#include "lib/types.h"

typedef HashNode<CryptoPP::Tiger> TigerNode;

class AssetMeta
{
public:
	AssetMeta(const boost::filesystem3::path& path, uint leafBlocks);

	TigerNode& operator[](const size_t offset);
	size_t size();
private:
	void repage(uint64_t offset);

	boost::iostreams::mapped_file_params _fp;
	boost::iostreams::mapped_file _f;

	size_t _leafBlocks;
	size_t _nodes_offset;
	size_t _file_size;
};

#endif // ASSETMETA_H
