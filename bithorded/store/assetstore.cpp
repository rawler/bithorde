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
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <utime.h>

#include <log4cplus/logger.h>
#include <log4cplus/loggingmacros.h>

#include "../../lib/random.h"

using namespace bithorded::store;
namespace fs = boost::filesystem;
using namespace std;

const fs::path ASSETS_DIR = "assets";
const fs::path TIGER_DIR = "tiger";

namespace bithorded {
	log4cplus::Logger storeLog = log4cplus::Logger::getInstance("store");
}

AssetStore::AssetStore(const boost::filesystem::path& baseDir) :
	_assetsFolder(baseDir/ASSETS_DIR),
	_tigerFolder(baseDir/TIGER_DIR)
{
}

void AssetStore::open()
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

void AssetStore::link(const BitHordeIds& ids, const boost::filesystem::path& assetPath)
{
	for (auto iter=ids.begin(); iter != ids.end(); iter++) {
		if (iter->type() == bithorde::HashType::TREE_TIGER) {
			fs::path link = _tigerFolder / base32encode(iter->id());
			if (fs::exists(fs::symlink_status(link)))
				fs::remove(link);

			// TODO: make links relative instead, so storage can be moved around a little.
			fs::create_symlink(fs::absolute(assetPath), link);
		}
	}
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
	for (auto iter=ids.begin(); iter != ids.end(); iter++) {
		if (iter->type() == bithorde::HashType::TREE_TIGER) {
			fs::path hashLink = _tigerFolder / base32encode(iter->id());
			boost::system::error_code e;
			auto assetFolder = fs::read_symlink(hashLink, e);
			if (e || !fs::is_directory(assetFolder)) {
				unlink(hashLink);
			} else if (checkAssetFolder(hashLink, assetFolder)) {
				return assetFolder;
			}
		}
	}
	return fs::path();
}

boost::filesystem::directory_iterator AssetStore::assetIterator()
{
	return fs::directory_iterator(_assetsFolder);
}

uintmax_t AssetStore::size()
{
	uintmax_t res=0;
	fs::directory_iterator end;
	for (auto iter=assetIterator(); iter != end; iter++) {
		res += assetFullSize(iter->path());
	}
	return res;
}

uintmax_t AssetStore::assetFullSize(const boost::filesystem::path& path)
{
	uintmax_t res=0;
	fs::directory_iterator end;
	for (fs::directory_iterator iter(path); iter != end; iter++) {
		res += fs::file_size(iter->path());
	}
	return res;
}

void AssetStore::removeAsset(const boost::filesystem::path& assetPath) noexcept
{
	if (fs::is_directory(assetPath)) {
		LOG4CPLUS_WARN(bithorded::storeLog, "removing asset " << assetPath.filename());
		fs::remove_all(assetPath);
	}
}

void AssetStore::unlink(const fs::path& linkPath) noexcept
{
	fs::remove(linkPath);
}

void AssetStore::unlinkAndRemove(const boost::filesystem::path& linkPath) noexcept
{
	boost::system::error_code e;
	auto asset = fs::read_symlink(linkPath, e);
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




