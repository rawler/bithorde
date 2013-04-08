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
#include <ctime>

#include <log4cplus/logger.h>
#include <log4cplus/loggingmacros.h>

using namespace bithorded;
using namespace bithorded::cache;

namespace fs = boost::filesystem;

namespace bithorded {
	namespace cache {
		log4cplus::Logger log = log4cplus::Logger::getInstance("cache");
	}
}

CacheManager::CacheManager(boost::asio::io_service& ioSvc,
                           bithorded::router::Router& router,
                           const boost::filesystem::path& baseDir, intmax_t size) :
	bithorded::store::AssetStore(baseDir),
	_baseDir(baseDir),
	_ioSvc(ioSvc),
	_router(router),
	_maxSize(size)
{
	if (!baseDir.empty())
		AssetStore::openOrCreate();
}

IAsset::Ptr CacheManager::openAsset(const boost::filesystem::path& assetPath)
{
	return boost::make_shared<CachedAsset>(assetPath);
}

IAsset::Ptr CacheManager::openAsset(const bithorde::BindRead& req)
{
	auto stored = boost::dynamic_pointer_cast<CachedAsset>(bithorded::store::AssetStore::openAsset(req));
	if (stored && (stored->status == bithorde::Status::SUCCESS)) {
		return stored;
	} else {
		auto upstream = _router.findAsset(req);
		if (auto upstream_ = boost::dynamic_pointer_cast<router::ForwardedAsset>(upstream)) {
			return boost::make_shared<CachingAsset>(*this, upstream_, stored);
		} else {
			return upstream;
		}
	}
}

CachedAsset::Ptr CacheManager::prepareUpload(uint64_t size)
{
	if ((!_baseDir.empty()) && makeRoom(size)) {
		fs::path assetFolder(AssetStore::newAssetDir());

		try {
			auto asset = boost::make_shared<CachedAsset>(assetFolder,size);
			asset->statusChange.connect(boost::bind(&CacheManager::linkAsset, this, CachedAsset::WeakPtr(asset)));
			return asset;
		} catch (const std::ios::failure& e) {
			LOG4CPLUS_ERROR(log, "Failed to create " << assetFolder << " for upload. Purging...");
			AssetStore::removeAsset(assetFolder);
			return CachedAsset::Ptr();
		}
	} else {
		return CachedAsset::Ptr();
	}
}

CachedAsset::Ptr CacheManager::prepareUpload(uint64_t size, const BitHordeIds& ids)
{
	auto res = prepareUpload(size);
	if (res)
		AssetStore::update_links(ids, res);
	return res;
}


IAsset::Ptr CacheManager::findAsset(const bithorde::BindRead& req)
{
	return AssetSessions::findAsset(req);
}

bool CacheManager::makeRoom(uint64_t size)
{
	while ((store::AssetStore::size()+size) > _maxSize) {
		auto looser = pickLooser();
		if (looser.empty())
			return false;
		else
			AssetStore::removeAsset(looser);
	}
	return true;
}

fs::path CacheManager::pickLooser() {
	// TODO: update mtime on access (support both FIFO and LRU?)
	fs::path looser;
	std::time_t oldest=-1;
	fs::directory_iterator end;
	for (auto iter=AssetStore::assetIterator(); iter != end; iter++) {
		auto age = fs::last_write_time(iter->path());
		if ((oldest == -1) || (age < oldest)) {
			oldest = age;
			looser = iter->path();
		}
	}

	return looser;
}

void CacheManager::linkAsset(CachedAsset::WeakPtr asset_)
{
	auto asset = asset_.lock();
	BitHordeIds ids;
	if (asset && asset->getIds(ids)) {
		LOG4CPLUS_DEBUG(log, "Linking " << ids << " to " << asset->folder());
		const char *data_path = (asset->folder()/"data").c_str();
		lutimes(data_path, NULL);

		AssetStore::update_links(ids, asset);
	}
}

