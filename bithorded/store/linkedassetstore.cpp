/*
    Copyright 2012 Ulrik Mikaelsson <ulrik.mikaelsson@gmail.com>

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

#include "linkedassetstore.hpp"

#include <boost/algorithm/string/predicate.hpp>
#include <boost/filesystem.hpp>
#include <boost/make_shared.hpp>
#include <string>
#include <time.h>
#include <utime.h>

#include <glog/logging.h>

using namespace std;

namespace asio = boost::asio;
namespace fs = boost::filesystem;

using namespace bithorded;

const fs::path META_DIR = ".bh_meta/assets";
const fs::path TIGER_DIR = ".bh_meta/tiger";

const int THREADPOOL_CONCURRENCY = 4;

LinkedAssetStore::LinkedAssetStore(boost::asio::io_service& ioSvc, const boost::filesystem3::path& baseDir) :
	_threadPool(THREADPOOL_CONCURRENCY),
	_ioSvc(ioSvc),
	_baseDir(baseDir),
	_assetsFolder(baseDir/META_DIR),
	_tigerFolder(baseDir/TIGER_DIR)
{
	if (!fs::exists(_baseDir))
		throw ios_base::failure("LinkedAssetStore: baseDir does not exist");
	if (!fs::exists(_assetsFolder))
		fs::create_directories(_assetsFolder);
	if (!fs::exists(_tigerFolder))
		fs::create_directories(_tigerFolder);
	srand(time(NULL));
}

struct HashTask : public Task {
	SourceAsset::Ptr asset;
	asio::io_service& io_svc;
	asio::io_service::work _work;
	LinkedAssetStore::ResultHandler handler;

	HashTask(SourceAsset::Ptr asset, asio::io_service& io_svc, LinkedAssetStore::ResultHandler handler )
		: asset(asset), io_svc(io_svc), _work(io_svc), handler(handler)
	{}
	
	void operator()() {
		asset->notifyValidRange(0, asset->size());

		io_svc.post(boost::bind(handler, asset));
		delete this;
	}
};

bool path_is_in(const fs::path& path, const fs::path& folder) {
	string path_(fs::absolute(path).string());
	string folder_(fs::absolute(folder).string()+'/');
	return boost::starts_with(path_, folder_);
}

string random_string(size_t len) {
	static const char alphanum[] =
		"0123456789"
		"ABCDEFGHIJKLMNOPQRSTUVWXYZ"
		"abcdefghijklmnopqrstuvwxyz";

	string s(len, ' ');
	for (size_t i = 0; i < len; ++i) {
		s[i] = alphanum[rand() % (sizeof(alphanum) - 1)];
	}

	return s;
}

bool LinkedAssetStore::addAsset(const boost::filesystem3::path& file, LinkedAssetStore::ResultHandler handler)
{
	if (!path_is_in(file, _baseDir)) {
		return false;
	} else {
		fs::path assetFolder;
		do {
			assetFolder = _assetsFolder / random_string(20);
		} while (fs::exists(assetFolder));

		fs::create_directory(assetFolder);
		fs::create_symlink(file, assetFolder/"data");

		SourceAsset::Ptr asset = boost::make_shared<SourceAsset>(assetFolder);
		HashTask* task = new HashTask(asset, _ioSvc, boost::bind(&LinkedAssetStore::_addAsset, this, _1, handler));
		_threadPool.post(*task);
		return true;
	}
}

void LinkedAssetStore::_addAsset(SourceAsset::Ptr& asset, LinkedAssetStore::ResultHandler upstream)
{
	BitHordeIds ids;
	if (asset.get() && asset->getIds(ids)) {
		const char *data_path = (asset->folder()/"data").c_str();
		lutimes(data_path, NULL);

		for (auto iter=ids.begin(); iter != ids.end(); iter++) {
			if (iter->type() == bithorde::HashType::TREE_TIGER) {
				fs::path link = _tigerFolder / base32encode(iter->id());
				if (fs::exists(fs::symlink_status(link)))
					fs::remove(link);

				// TODO: make links relative instead, so storage can be moved around a little.
				fs::create_symlink(fs::absolute(asset->folder()), link);
			}
		}
	}
	upstream(asset);
}

void purgeLink(const fs::path& path) {
	fs::remove(path);
}

void purgeLinkAndAsset(const fs::path& path) {
	boost::system::error_code e;
	auto asset = fs::read_symlink(path, e);
	purgeLink(path);
	if (!e && fs::is_directory(asset))
		fs::remove_all(asset);
}

enum LinkStatus{
	OK,
	BROKEN,
	OUTDATED,
};

LinkStatus validateDataSymlink(const fs::path& path) {
	struct stat linkStat, dataStat;

	const char* c_path = path.c_str();
	if (lstat(c_path, &linkStat) ||
	    !S_ISLNK(linkStat.st_mode) ||
	    stat(c_path, &dataStat) ||
	    !S_ISREG(dataStat.st_mode))
		return BROKEN;
	if (linkStat.st_mtime >= dataStat.st_mtime)
		return OK;
	else
		return OUTDATED;
}

void noop(Asset::Ptr) {}

SourceAsset::Ptr openAssetFolder(const fs::path& referrer, const fs::path& assetFolder) {
	auto assetDataPath = assetFolder/"data";
	switch (validateDataSymlink(assetDataPath)) {
	case OUTDATED:
		LOG(WARNING) << "outdated asset detected, " << assetFolder << endl;
		purgeLink(referrer);
		fs::remove(referrer/"meta");
	case OK:
		return boost::make_shared<SourceAsset>(assetFolder);
		break;

	case BROKEN:
		LOG(WARNING) << "broken asset detected, " << assetFolder << endl;
		purgeLinkAndAsset(referrer);
	default:
		break;
	}
	return SourceAsset::Ptr();
}

SourceAsset::Ptr LinkedAssetStore::_openTiger(const std::string& tigerId)
{
	SourceAsset::Ptr asset;
	if (_tigerMap.count(tigerId))
		asset = _tigerMap[tigerId].lock();
	if (!asset) {
		fs::path hashLink = _tigerFolder / base32encode(tigerId);
		boost::system::error_code e;
		auto assetFolder = fs::read_symlink(hashLink, e);
		if (e || !fs::is_directory(assetFolder)) {
			purgeLink(hashLink);
		} else if (asset = openAssetFolder(hashLink, assetFolder)) {
			if (asset->hasRootHash()) {
				_tigerMap[tigerId] = asset;
			} else {
				asset.reset();
				LOG(WARNING) << "Unhashed asset detected, hashing" << endl;
				_threadPool.post(*new HashTask(asset, _ioSvc, boost::bind(&LinkedAssetStore::_addAsset, this, _1, &noop)));
			}
		}
	}
	return asset;
}

Asset::Ptr LinkedAssetStore::findAsset(const BitHordeIds& ids)
{
	SourceAsset::Ptr asset;
	for (auto iter=ids.begin(); iter != ids.end(); iter++) {
		if (iter->type() == bithorde::HashType::TREE_TIGER
			&& (asset = _openTiger(iter->id())))
			break;
	}
	return asset;
}


