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

boost::filesystem::path AssetStore::newAsset()
{
	fs::path assetPath;
	do {
		assetPath = _assetsFolder / randomAlphaNumeric(20);
	} while (fs::exists( assetPath ));
	return assetPath;
}

void AssetStore::purge_links(const boost::shared_ptr< StoredAsset >& asset, const BitHordeIds& except)
{
	// TODO: use _index for this
	auto assetId = asset->id();
	fs::directory_iterator end;
	auto tgt = _assetsFolder / assetId;
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

	fs::path link = _tigerFolder / tigerId.base32();
	if (fs::exists(fs::symlink_status(link)))
		fs::remove(link);

	fs::create_relative_symlink(_assetsFolder / asset->id(), link);
}


boost::filesystem::path AssetStore::resolveIds(const BitHordeIds& ids)
{
	auto tigerId = findBithordeId(ids, bithorde::HashType::TREE_TIGER);
	if (!tigerId.empty()) {
		fs::path hashLink = _tigerFolder / tigerId.base32();
		switch (fs::status(hashLink).type()) {
			case fs::file_type::regular_file:
			case fs::file_type::directory_file:
				return hashLink;
			default:
				unlink(hashLink);
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
	struct stat res_stat;
	if (stat(path.c_str(), &res_stat) != 0) {
		LOG4CPLUS_WARN(bithorded::storeLog, "failed stat:ing asset " << path.native());
		return 0;
	}
	if (S_ISREG(res_stat.st_mode)) {
		res += res_stat.st_blocks * 512;
	} else if (S_ISDIR(res_stat.st_mode)) {
		fs::directory_iterator end;
		for (fs::directory_iterator iter(path); iter != end; iter++) {
			if (stat(iter->path().c_str(), &res_stat) == 0) {
				res += res_stat.st_blocks * 512;
			} else {
				LOG4CPLUS_WARN(bithorded::storeLog, "failed stat:ing asset-part " << iter->path().native());
			}
		}
	} else {
		LOG4CPLUS_WARN(bithorded::storeLog, "unknown type for asset " << path.native());
	}
	return res;
}

namespace {
	boost::filesystem::directory_iterator end_dir_itr;
}

uintmax_t remove_file_recursive(const fs::path& path) {
	uintmax_t size_freed = 0;
	boost::system::error_code err;

	struct stat res_stat;
	if (stat(path.c_str(), &res_stat) == 0) {
		size_freed += res_stat.st_blocks * 512;
		if (S_ISDIR(res_stat.st_mode)) {
			for (fs::directory_iterator itr(path); itr != end_dir_itr; ++itr)
				size_freed += remove_file_recursive(itr->path());
		}
		fs::remove(path, err);
		if (err) {
			LOG4CPLUS_WARN(bithorded::storeLog, "error removing file " << path << "; " << err);
		}
	} else {
		LOG4CPLUS_WARN(bithorded::storeLog, "failed stat:ing file " << path.native());
	}
	return size_freed;
}

uintmax_t AssetStore::removeAsset(const boost::filesystem::path& assetPath) noexcept
{
	LOG4CPLUS_INFO(bithorded::storeLog, "removing asset " << assetPath.filename());
	return remove_file_recursive(assetPath);
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
	auto linkPath = resolveIds(req.ids());
	auto assetPath = linkPath.empty() ? fs::path() : fs::canonical(linkPath);
	if (assetPath.empty())
		return IAsset::Ptr();
	else try {
		if (auto res = openAsset(assetPath)) {
			return res;
		} else {
			unlinkAndRemove(linkPath);
		}
	} catch (const boost::system::system_error& e) {
		if (e.code().value() == bsys::errc::no_such_file_or_directory) {
			LOG4CPLUS_ERROR(storeLog, "Linked asset " << linkPath << "broken. Purging...");
			unlinkAndRemove(linkPath);
		} else if (e.code().value() == bsys::errc::file_exists) {
			LOG4CPLUS_ERROR(storeLog, "Linked asset " << linkPath << "exists with wrong size. Purging...");
			unlinkAndRemove(linkPath);
		} else {
			LOG4CPLUS_ERROR(storeLog, "Failed to open " << linkPath << " with unknown error " << e.what());
		}
	} catch (const std::ios::failure& e) {
		LOG4CPLUS_ERROR(storeLog, "Failed to open " << assetPath << " with unknown error " << e.what());
	}
	return IAsset::Ptr();
}
