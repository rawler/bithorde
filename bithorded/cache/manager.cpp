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

CacheManager::CacheManager( GrandCentralDispatch& gcd, IAssetSource& router, const boost::filesystem::path& baseDir, intmax_t size ) :
	bithorded::store::AssetStore(baseDir),
	_baseDir(baseDir),
	_gcd(gcd),
	_router(router),
	_maxSize(size)
{
	if (!baseDir.empty())
		AssetStore::openOrCreate();
}

void CacheManager::describe(management::Info& target) const
{
	auto size = store::AssetStore::size();
	target << "capacity: " << (_maxSize/(1024*1024)) << "MB, size: " << (size/(1024*1024)) << "MB (" << (int)((size*100)/_maxSize) << "%)";
}

void CacheManager::inspect(management::InfoList& target) const
{
	target.append("path") << _baseDir;
	target.append("capacity") << _maxSize;
	target.append("size") << store::AssetStore::size();
}

IAsset::Ptr CacheManager::openAsset(const boost::filesystem::path& assetPath)
{
	return CachedAsset::open(_gcd, assetPath);
}

IAsset::Ptr CacheManager::openAsset(const bithorde::BindRead& req)
{
	if (_baseDir.empty())
		return IAsset::Ptr();
	auto stored = boost::dynamic_pointer_cast<CachedAsset>(bithorded::store::AssetStore::openAsset(req));
	if (stored && (stored->status->status() == bithorde::Status::SUCCESS)) {
		return stored;
	} else {
		auto upstream = _router.findAsset(req);
		if (auto upstream_ = boost::dynamic_pointer_cast<bithorded::IAsset>(upstream->shared())) {
			return boost::make_shared<CachingAsset>(*this, upstream_, stored);
		} else {
			return upstream->shared();
		}
	}
}

CachedAsset::Ptr CacheManager::prepareUpload(uint64_t size)
{
	if ((!_baseDir.empty()) && makeRoom(size)) {
		fs::path assetPath(AssetStore::newAsset());

		try {
			auto asset = CachedAsset::create(_gcd, assetPath, size);
			asset->status.onChange.connect(boost::bind(&CacheManager::linkAsset, this, CachedAsset::WeakPtr(asset)));
			return asset;
		} catch (const std::ios::failure& e) {
			LOG4CPLUS_ERROR(log, "Failed to create " << assetPath << " for upload (" << e.what() << "). Purging...");
			AssetStore::removeAsset(assetPath);
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

UpstreamRequestBinding::Ptr CacheManager::findAsset(const bithorde::BindRead& req)
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
	if (asset && asset->status->ids_size()) {
		auto& ids = asset->status->ids();
		auto assetPath = (assetsFolder() / asset->id());
		LOG4CPLUS_DEBUG(log, "Linking " << ids << " to " << assetPath);
		lutimes(assetPath.c_str(), NULL);

		AssetStore::update_links(ids, asset);
	}
}

