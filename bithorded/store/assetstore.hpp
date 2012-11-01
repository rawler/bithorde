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


#ifndef BITHORDED_STORE_ASSETSTORE_HPP
#define BITHORDED_STORE_ASSETSTORE_HPP

#include <boost/filesystem/path.hpp>

#include "../../lib/hashes.h"

namespace bithorded { namespace store {

class AssetStore
{
	boost::filesystem::path _assetsFolder;
	boost::filesystem::path _tigerFolder;
public:
	AssetStore(const boost::filesystem::path& baseDir);

	void open();

	boost::filesystem::path newAssetDir();

	void link(const BitHordeIds& ids, const boost::filesystem::path& assetPath);

	boost::filesystem::path resolveIds(const BitHordeIds& ids);

	static void unlink(const boost::filesystem::path& linkPath);
	static void unlinkAndRemove(const boost::filesystem::path& linkPath);
};
} }

#endif // BITHORDED_STORE_ASSETSTORE_HPP
