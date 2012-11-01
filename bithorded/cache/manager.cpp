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


#include "manager.hpp"

#include <boost/filesystem.hpp>

using namespace bithorded;
using namespace bithorded::cache;

namespace fs = boost::filesystem;

CacheManager::CacheManager(boost::asio::io_service& ioSvc,
                           bithorded::router::Router& router,
                           const boost::filesystem3::path& baseDir, int64_t size) :
	_baseDir(baseDir),
	_ioSvc(ioSvc),
	_router(router),
	_store(baseDir)
{
	if (!baseDir.empty())
		_store.open();
}

IAsset::Ptr CacheManager::findAsset(const BitHordeIds& ids)
{
	if (_baseDir.empty())
		return IAsset::Ptr();

	auto path = _store.resolveIds(ids);
	if (!path.empty()) {
		auto asset = boost::make_shared<CachedAsset>(path);
		if (asset->hasRootHash()) {
// 			if (tigerId.size())
// 				_tigerMap[tigerId] = asset;
			return asset;
		} else {
			// TODO
//			LOG4CPLUS_WARN(sourceLog, "Incomplete asset detected, TODO");
// 			_threadPool.post(*new HashTask(asset, _ioSvc));
		}
	}
	return IAsset::Ptr();
}

IAsset::Ptr CacheManager::prepareUpload(uint64_t size)
{
	if (_baseDir.empty()) {
		return IAsset::Ptr();
	} else {
		fs::path assetFolder(_store.newAssetDir());
		fs::create_directory(assetFolder);

		auto asset = boost::make_shared<CachedAsset>(assetFolder,size);
		asset->statusChange.connect(boost::bind(&CacheManager::linkAsset, this, asset.get()));
		return asset;
	}
}

void CacheManager::linkAsset(CachedAsset* asset)
{
	BitHordeIds ids;
	if (asset && asset->getIds(ids)) {
		std::cerr << "Linking" << std::endl;
		const char *data_path = (asset->folder()/"data").c_str();
		lutimes(data_path, NULL);

		_store.link(ids, asset->folder());
	}
}

