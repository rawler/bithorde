/*
    Copyright 2016 Ulrik Mikaelsson <ulrik.mikaelsson@gmail.com>

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
	auto diskUsage = store::AssetStore::diskUsage();
	auto diskAllocation = _index.totalDiskAllocation();
	target << "capacity: " << (_maxSize/(1024*1024)) << "MB, used: " << (diskUsage/(1024*1024)) << "MB (" << (int)((diskUsage*100)/_maxSize) << "\%), allocated: " << (diskAllocation/(1024*1024)) << "MB";
}

void CacheManager::inspect(management::InfoList& target) const
{
	target.append("path") << _baseDir;
	target.append("capacity") << _maxSize;
	target.append("used") << store::AssetStore::diskUsage();
	return AssetStore::inspect(target);
}

IAsset::Ptr CacheManager::openAsset(const boost::filesystem::path& assetPath)
{
	return CachedAsset::open(_gcd, assetPath);
}

IAsset::Ptr CacheManager::openAsset(const bithorde::BindRead& req)
{
	if (_baseDir.empty())
		return IAsset::Ptr();
	auto stored = std::dynamic_pointer_cast<CachedAsset>(bithorded::store::AssetStore::openAsset(req));
	if (stored && (stored->status->status() == bithorde::Status::SUCCESS)) {
		return stored;
	} else {
		auto upstream = _router.findAsset(req);
		if (auto upstream_ = std::dynamic_pointer_cast<bithorded::IAsset>(upstream->shared())) {
			return std::make_shared<CachingAsset>(*this, upstream_, stored);
		} else {
			return upstream->shared();
		}
	}
}

void CacheManager::updateAsset(const std::shared_ptr<store::StoredAsset>& asset)
{
	return AssetStore::update_asset(asset->status->ids(), asset);
}

CachedAsset::Ptr CacheManager::prepareUpload(uint64_t size)
{
	if ((!_baseDir.empty()) && makeRoom(size)) {
		fs::path assetPath(AssetStore::newAsset());

		try {
			auto asset = CachedAsset::create(_gcd, assetPath, size);
			auto weakAsset = CachedAsset::WeakPtr(asset);
			asset->status.onChange.connect([=](const bithorde::AssetStatus&, const bithorde::AssetStatus&){ linkAsset(weakAsset); });
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
		AssetStore::update_asset(ids, res);
	return res;
}

UpstreamRequestBinding::Ptr CacheManager::findAsset(const bithorde::BindRead& req)
{
	return AssetSessions::findAsset(req);
}

bool CacheManager::makeRoom(uint64_t size)
{
	int64_t needed = (store::AssetStore::diskUsage()+size) - _maxSize;
	int64_t freed = 0;
	while (needed > freed) {
		auto looser = _index.pickLooser();
		if (looser.empty()) {
			return false;
		} else {
			freed += AssetStore::removeAsset(looser);
		}
	}
	return true;
}

void CacheManager::linkAsset(CachedAsset::WeakPtr asset_)
{
	auto asset = asset_.lock();
	if (asset) {
		auto& ids = asset->status->ids();
		if (ids.size()) {
			LOG4CPLUS_DEBUG(log, "Linking " << ids << " to " << asset->id());
		}

		AssetStore::update_asset(ids, asset);
	}
}
