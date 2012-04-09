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


#include "linkedassetstore.hpp"

#include <boost/algorithm/string/predicate.hpp>
#include <boost/filesystem.hpp>
#include <boost/make_shared.hpp>
#include <string>
#include <time.h>

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
	Asset::Ptr asset;
	asio::io_service& io_svc;
	asio::io_service::work _work;
	LinkedAssetStore::ResultHandler handler;

	HashTask(Asset::Ptr asset, asio::io_service& io_svc, LinkedAssetStore::ResultHandler handler )
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

		Asset::Ptr asset = boost::make_shared<Asset>(assetFolder);
		HashTask* task = new HashTask(asset, _ioSvc, boost::bind(&LinkedAssetStore::_addAsset, this, _1, handler));
		_threadPool.post(*task);
		return true;
	}
}

void LinkedAssetStore::_addAsset(Asset::Ptr& asset, LinkedAssetStore::ResultHandler upstream)
{
	BitHordeIds ids;
	if (asset.get() && asset->getIds(ids)) {
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

Asset::Ptr LinkedAssetStore::findAsset(const BitHordeIds& ids)
{
	for (auto iter=ids.begin(); iter != ids.end(); iter++) {
		if (iter->type() == bithorde::HashType::TREE_TIGER) {
			fs::path link = _tigerFolder / base32encode(iter->id());
			boost::system::error_code e;
			auto asset = fs::read_symlink(link, e);
			if (!e && fs::is_directory(asset)) {
				return boost::make_shared<Asset>(asset);
			}
		}
	}
	return Asset::Ptr();
}


