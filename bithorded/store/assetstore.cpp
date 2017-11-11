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
#include "assetstore.hpp"

#include <boost/filesystem.hpp>
#include <boost/algorithm/string.hpp>
#include <set>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <utime.h>

#include "asset.hpp"
#include <lib/hashes.h>
#include <lib/random.h>
#include <bithorded/lib/log.hpp>
#include <bithorded/lib/management.hpp>
#include <bithorded/lib/relativepath.hpp>

using namespace bithorded;
using namespace bithorded::store;
namespace fs = boost::filesystem;
namespace bsys = boost::system;
using namespace std;

const fs::path ASSETS_DIR = "assets";
const fs::path TIGER_DIR = "tiger";

namespace bithorded {
	Logger storeLog;
}

AssetStore::AssetStore(const boost::filesystem::path& baseDir) :
	_baseFolder(baseDir),
	_assetsFolder(baseDir.empty() ? fs::path() : (baseDir/ASSETS_DIR)),
	_tigerFolder(baseDir.empty() ? fs::path() : (baseDir/TIGER_DIR))
{
}

void AssetStore::inspect(management::InfoList& target) const
{
	return _index.inspect(target);
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
	_baseFolder = fs::canonical(_baseFolder);
	_assetsFolder = fs::canonical(_assetsFolder);
	_tigerFolder = fs::canonical(_tigerFolder);
	loadIndex();
}

boost::filesystem::path AssetStore::newAsset()
{
	fs::path assetPath;
	std::string assetId;
	do {
		assetId = randomAlphaNumeric(20);
		assetPath = _assetsFolder / assetId;
	} while (fs::exists( assetPath ));
	_index.addAsset(assetId, bithorde::Id::EMPTY, 0, 0, time(NULL));
	return assetPath;
}

void AssetStore::updateAsset(const bithorde::Ids& ids, const std::shared_ptr<StoredAsset>& asset)
{
	auto tigerId = findBithordeId(ids, bithorde::HashType::TREE_TIGER);

	auto assetId = asset->id();

	auto oldTiger = _index.lookupAsset(assetId);
	if (tigerId.empty()) {
		// Updates with empty TigerId won't overwrite.
		tigerId = oldTiger;
	} else if ((!oldTiger.empty()) && (oldTiger != tigerId)) {
		BOOST_LOG_SEV(bithorded::storeLog, warning) << "asset " << assetId << " were linked by the wrong tthsum " << oldTiger;
		unlink(_tigerFolder/oldTiger);
	}

	auto assetPath = _assetsFolder / assetId;
	_index.addAsset(assetId, tigerId, assetDiskUsage(assetPath), assetDiskAllocated(assetPath), fs::last_write_time(assetPath));

	if (!tigerId.empty()) {
		fs::path link = _tigerFolder / tigerId.base32();
		if (fs::exists(fs::symlink_status(link)))
			fs::remove(link);
		fs::create_relative_symlink(_assetsFolder / assetId, link);
	}
}

uint64_t AssetStore::diskUsage() const
{
	return _index.totalDiskUsage();
}

uint64_t AssetStore::assetDiskAllocated(const boost::filesystem::path& path) const
{
	uint64_t res=0;
    if(fs::is_directory(path)) {
	    fs::recursive_directory_iterator end;
	    for(fs::recursive_directory_iterator it(path); it != end; ++it) {
	        if(!fs::is_directory(*it))
	            res+=fs::file_size(*it);
	    }
	} else {
		res = fs::file_size(path);
	}
	return res;
}

uint64_t AssetStore::assetDiskUsage(const boost::filesystem::path& path) const
{
	uint64_t res=0;
	struct stat res_stat;
	if (stat(path.c_str(), &res_stat) != 0) {
		BOOST_LOG_SEV(bithorded::storeLog, warning) << "failed stat:ing asset " << path.native();
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
				BOOST_LOG_SEV(bithorded::storeLog, warning) << "failed stat:ing asset-part " << iter->path().native();
			}
		}
	} else {
		BOOST_LOG_SEV(bithorded::storeLog, warning) << "unknown type for asset " << path.native();
	}
	return res;
}

namespace {
	boost::filesystem::directory_iterator end_dir_itr;
}

uint64_t remove_file_recursive(const fs::path& path) {
	uint64_t size_freed = 0;
	boost::system::error_code err;

	struct stat res_stat;
	if (lstat(path.c_str(), &res_stat) == 0) {
		size_freed += res_stat.st_blocks * 512;
		if (S_ISDIR(res_stat.st_mode)) {
			for (fs::directory_iterator itr(path); itr != end_dir_itr; ++itr)
				size_freed += remove_file_recursive(itr->path());
		}
		fs::remove(path, err);
		if (err) {
			BOOST_LOG_SEV(bithorded::storeLog, warning) << "error removing file " << path << "; " << err;
		}
	} else {
		BOOST_LOG_SEV(bithorded::storeLog, warning) << "failed stat:ing file " << path.native();
	}
	return size_freed;
}

uint64_t AssetStore::removeAsset(const std::string& assetId) noexcept
{
	return removeAsset(_assetsFolder / assetId);
}

uint64_t AssetStore::removeAsset(const boost::filesystem::path& assetPath) noexcept
{
	BOOST_LOG_SEV(bithorded::storeLog, info) << "removing asset " << assetPath.filename();
	auto tigerId = _index.removeAsset(assetPath.filename().native());
	if (!tigerId.empty()) {
		unlink(_tigerFolder / tigerId);
	}
	return remove_file_recursive(assetPath);
}

void AssetStore::unlink(const fs::path& linkPath) noexcept
{
	boost::system::error_code err;
	fs::remove(linkPath, err);
	if (err && (err.value() != boost::system::errc::no_such_file_or_directory)) {
		BOOST_LOG_SEV(bithorded::storeLog, warning) << "error removing asset-link " << linkPath << "; " << err;
	}
}

void AssetStore::loadIndex()
{
	boost::system::error_code ec;
	fs::directory_iterator enddir;
	uint64_t size_cleared = 0;

	BOOST_LOG_SEV(bithorded::storeLog, debug) << "starting scan of " << _tigerFolder;

	// Iterate through tigerFolder, and add any assets found matching
	for ( auto fi = fs::directory_iterator(_tigerFolder); fi != enddir; fi++ ) {
		auto tigerLink = fi->path();
		auto assetPath = read_symlink(tigerLink, ec);
		if (ec || assetPath.empty()) {
			continue;
		}
		try {
			assetPath = fs::canonical(assetPath, _tigerFolder);
		} catch (fs::filesystem_error) {
			BOOST_LOG_SEV(bithorded::storeLog, warning) << "dangling link in " << tigerLink;
			unlink(tigerLink);
			continue;
		}
		if (!boost::starts_with(assetPath, _assetsFolder)) {
			std::ostringstream err;
			err << "wild link in " << tigerLink << " pointing to " << assetPath;
			throw std::runtime_error(err.str());
		}

		auto assetUsed = assetDiskUsage(assetPath);
		auto assetAllocated = assetDiskAllocated(assetPath);
		auto fillPercent = (assetUsed * 100) / assetAllocated;

		if (fillPercent >= 3) {
			_index.addAsset(assetPath.filename().native(), bithorde::Id::fromBase32(tigerLink.filename().native()), assetUsed, assetAllocated, fs::last_write_time(assetPath));
		} else {
			BOOST_LOG_SEV(bithorded::storeLog, debug) << "removing almost empty asset: urn:tree:tiger:" << tigerLink.filename();
			unlink(tigerLink);
			size_cleared += remove_file_recursive(assetPath);
		}
	}

	BOOST_LOG_SEV(bithorded::storeLog, debug) << "starting scan of " << _assetsFolder;

	// Iterate through assetFolder, and remove any assets not found in index
	for ( auto fi = fs::directory_iterator(_assetsFolder); fi != enddir; fi++ ) {
		auto assetPath = fi->path();
		auto tigerId = _index.lookupAsset(assetPath.filename().native());
		if (tigerId.empty()) {
			BOOST_LOG_SEV(bithorded::storeLog, info) << "found " << assetPath << " without referencing tigerId, removing";
			size_cleared += remove_file_recursive(assetPath);
		}
	}

	BOOST_LOG_SEV(bithorded::storeLog, info) << "Scan finished. " << _index.assetCount() << " assets, using " << (_index.totalDiskUsage()/1048576) << "MB. " << (size_cleared/1048576) << "MB cleared.";
}

IAsset::Ptr AssetStore::openAsset(const bithorde::BindRead& req)
{
	auto tigerId = findBithordeId(req.ids(), bithorde::HashType::TREE_TIGER);
	if (tigerId.empty())
		return IAsset::Ptr();
	auto assetId = _index.lookupTiger(tigerId);
	if (assetId.empty())
		return IAsset::Ptr();

	auto assetPath = _assetsFolder / assetId;
	try {
		if (auto res = openAsset(assetPath)) {
			updateAsset(res->status->ids(), static_pointer_cast<StoredAsset>(res));
			return res;
		} else {
			removeAsset(assetPath);
		}
	} catch (const boost::system::system_error& e) {
		if (e.code().value() == bsys::errc::no_such_file_or_directory) {
			BOOST_LOG_SEV(storeLog, error) << "Linked asset " << assetPath << "broken. Purging...";
			removeAsset(assetPath);
		} else if (e.code().value() == bsys::errc::file_exists) {
			BOOST_LOG_SEV(storeLog, error) << "Linked asset " << assetPath << "exists with wrong size. Purging...";
			removeAsset(assetPath);
		} else {
			BOOST_LOG_SEV(storeLog, error) << "Failed to open " << assetPath << " with unknown error " << e.what();
		}
	} catch (const std::ios::failure& e) {
		BOOST_LOG_SEV(storeLog, error) << "Failed to open " << assetPath << " with unknown error " << e.what();
	}
	return IAsset::Ptr();
}
