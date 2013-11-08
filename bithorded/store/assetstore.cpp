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
#include "assetstore.hpp"

#include <boost/filesystem.hpp>
#include <set>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <utime.h>

#include <log4cplus/logger.h>
#include <log4cplus/loggingmacros.h>

#include "asset.hpp"
#include "../../lib/hashes.h"
#include "../../lib/random.h"
#include "../lib/relativepath.hpp"

using namespace bithorded;
using namespace bithorded::store;
namespace fs = boost::filesystem;
namespace bsys = boost::system;
using namespace std;

const fs::path ASSETS_DIR = "assets";
const fs::path TIGER_DIR = "tiger";

namespace bithorded {
	log4cplus::Logger storeLog = log4cplus::Logger::getInstance("store");
}

AssetStore::AssetStore(const boost::filesystem::path& baseDir) :
	_baseFolder(baseDir),
	_assetsFolder(baseDir.empty() ? fs::path() : (baseDir/ASSETS_DIR)),
	_tigerFolder(baseDir.empty() ? fs::path() : (baseDir/TIGER_DIR))
{
}

const boost::filesystem::path& AssetStore::assetsFolder() {
	return _assetsFolder;
}

void AssetStore::openOrCreate()
{
	if (!fs::exists(_assetsFolder))
		fs::create_directories(_assetsFolder);
	if (!fs::exists(_tigerFolder))
		fs::create_directories(_tigerFolder);
}

boost::filesystem::path AssetStore::newAssetDir()
{
	fs::path assetFolder;
	do {
		assetFolder = _assetsFolder / randomAlphaNumeric(20);
	} while (fs::exists(assetFolder));
	fs::create_directory(assetFolder);
	return assetFolder;
}

void AssetStore::purge_links(const boost::shared_ptr< StoredAsset >& asset, const BitHordeIds& except)
{
	fs::directory_iterator end;
	auto tgt = _assetsFolder / asset->id();
	boost::system::error_code ec;
	std::set<fs::path> exceptions;
	for (auto iter = except.begin(); iter != except.end(); ++iter) {
		if (iter->type() == bithorde::HashType::TREE_TIGER)
			exceptions.insert(base32encode(iter->id()));
	}
	for (fs::directory_iterator iter(_tigerFolder); iter != end; ++iter) {
		if (fs::is_symlink(iter->status())) {
			if ((fs::absolute(fs::read_symlink(_tigerFolder/iter->path(), ec), _tigerFolder) == tgt) && !exceptions.count(iter->path()))
				unlink(_tigerFolder / iter->path());
		}
	}
}

void AssetStore::update_links(const BitHordeIds& ids, const boost::shared_ptr<StoredAsset>& asset)
{
	auto tigerId = findBithordeId(ids, bithorde::HashType::TREE_TIGER);
	if (tigerId.empty())
		return;
	purge_links(asset, ids);

	fs::path link = _tigerFolder / base32encode(tigerId);
	if (fs::exists(fs::symlink_status(link)))
		fs::remove(link);

	fs::create_relative_symlink(_assetsFolder / asset->id(), link);
}

enum LinkStatus{
	OK,
	BROKEN,
	OUTDATED,
};

LinkStatus validateData(const fs::path& assetDataPath) {
	struct stat linkStat, dataStat;

	const char* c_path = assetDataPath.c_str();
	if (lstat(c_path, &linkStat) ||
	    !(S_ISLNK(linkStat.st_mode) || S_ISREG(linkStat.st_mode)) ||
	    stat(c_path, &dataStat) ||
	    !S_ISREG(dataStat.st_mode))
		return BROKEN;
	if (linkStat.st_mtime >= dataStat.st_mtime)
		return OK;
	else
		return OUTDATED;
}

bool checkAssetFolder(const fs::path& referrer, const fs::path& assetFolder) {
	auto assetDataPath = assetFolder/"data";
	switch (validateData(assetDataPath)) {
	case OK:
		return true;
	case OUTDATED:
		LOG4CPLUS_WARN(bithorded::storeLog, "outdated asset detected, " << assetFolder);
		AssetStore::unlink(referrer);
		fs::remove(referrer/"meta");
		return false;
	case BROKEN:
		LOG4CPLUS_WARN(bithorded::storeLog, "broken asset detected, " << assetFolder);
		AssetStore::unlinkAndRemove(referrer);
		return false;
	}
	return false;
}

boost::filesystem::path AssetStore::resolveIds(const BitHordeIds& ids)
{
	if (_tigerFolder.empty())
		fs::path();
	auto tigerId = findBithordeId(ids, bithorde::HashType::TREE_TIGER);
	if (tigerId.size()) {
		fs::path hashLink = _tigerFolder / base32encode(tigerId);
		boost::system::error_code e;
		auto assetFolder = fs::canonical(hashLink, e);
		if (e || !fs::is_directory(assetFolder)) {
			unlink(hashLink);
		} else if (checkAssetFolder(hashLink, assetFolder)) {
			return assetFolder;
		}
	}
	return fs::path();
}

boost::filesystem::directory_iterator AssetStore::assetIterator() const
{
	return fs::directory_iterator(_assetsFolder);
}

uintmax_t AssetStore::size() const
{
	if (_baseFolder.empty())
		return 0;
	uintmax_t res(0);
	fs::directory_iterator end;
	for (auto iter=assetIterator(); iter != end; iter++) {
		res += assetFullSize(iter->path());
	}
	return res;
}

uintmax_t AssetStore::assetFullSize(const boost::filesystem::path& path) const
{
	uintmax_t res=0;
	fs::directory_iterator end;
	for (fs::directory_iterator iter(path); iter != end; iter++) {
		struct stat res_stat;
		if (stat(iter->path().c_str(), &res_stat) == 0)
			res += res_stat.st_blocks * 512;
	}
	return res;
}

void AssetStore::removeAsset(const boost::filesystem::path& assetPath) noexcept
{
	if (fs::is_directory(assetPath)) {
		LOG4CPLUS_WARN(bithorded::storeLog, "removing asset " << assetPath.filename());
		boost::system::error_code err;
		fs::remove_all(assetPath, err);
		if (err && (err.value() != boost::system::errc::no_such_file_or_directory)) {
			LOG4CPLUS_WARN(bithorded::storeLog, "error removing asset " << assetPath << "; " << err);
		}
	}
}

void AssetStore::unlink(const fs::path& linkPath) noexcept
{
	boost::system::error_code err;
	fs::remove(linkPath, err);
	if (err && (err.value() != boost::system::errc::no_such_file_or_directory)) {
		LOG4CPLUS_WARN(bithorded::storeLog, "error removing asset-link " << linkPath << "; " << err);
	}
}

void AssetStore::unlinkAndRemove(const boost::filesystem::path& linkPath) noexcept
{
	boost::system::error_code e;
	auto asset = fs::canonical(linkPath, e);
	unlink(linkPath);
	if (!e)
		removeAsset(asset);
}

void AssetStore::unlinkAndRemove(const BitHordeIds& ids) noexcept
{
	for (auto iter=ids.begin(); iter != ids.end(); iter++) {
		if (iter->type() == bithorde::HashType::TREE_TIGER) {
			fs::path hashLink = _tigerFolder / base32encode(iter->id());
			unlinkAndRemove(hashLink);
		}
	}
}

IAsset::Ptr AssetStore::openAsset(const bithorde::BindRead& req)
{
	auto assetPath = resolveIds(req.ids());
	if (assetPath.empty())
		return IAsset::Ptr();
	else try {
		return openAsset(assetPath);
	} catch (const boost::system::system_error& e) {
		if (e.code().value() == bsys::errc::no_such_file_or_directory) {
			LOG4CPLUS_ERROR(storeLog, "Linked asset " << assetPath << "broken. Purging...");
			unlinkAndRemove(req.ids());
		} else if (e.code().value() == bsys::errc::file_exists) {
			LOG4CPLUS_ERROR(storeLog, "Linked asset " << assetPath << "exists with wrong size. Purging...");
			unlinkAndRemove(req.ids());
		} else {
			LOG4CPLUS_ERROR(storeLog, "Failed to open " << assetPath << " with unknown error " << e.what());
		}
	} catch (const std::ios::failure& e) {
		LOG4CPLUS_ERROR(storeLog, "Failed to open " << assetPath << " with unknown error " << e.what());
	}
	return IAsset::Ptr();
}
