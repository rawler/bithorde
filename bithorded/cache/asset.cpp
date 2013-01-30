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


#include "asset.hpp"

bithorded::cache::CachedAsset::CachedAsset(const boost::filesystem::path& metaFolder) :
	StoredAsset(metaFolder)
{
	setStatus(bithorde::SUCCESS);
}

bithorded::cache::CachedAsset::CachedAsset(const boost::filesystem::path& metaFolder, uint64_t size) :
	StoredAsset(metaFolder, size)
{
	setStatus(bithorde::SUCCESS);
}

size_t bithorded::cache::CachedAsset::write(uint64_t offset, const std::string& data)
{
	_file.write(offset, data.data(), data.length());
	notifyValidRange(offset, data.length());
	updateStatus();
	return 0;
}
