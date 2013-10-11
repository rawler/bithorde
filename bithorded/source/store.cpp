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

#include "store.hpp"

#include <boost/algorithm/string/predicate.hpp>
#include <boost/filesystem.hpp>
#include <boost/make_shared.hpp>
#include <string>

#include <log4cplus/logger.h>
#include <log4cplus/loggingmacros.h>

#include "../lib/relativepath.hpp"
#include "../lib/grandcentraldispatch.hpp"

using namespace std;

namespace asio = boost::asio;
namespace fs = boost::filesystem;

using namespace bithorded;
using namespace bithorded::source;

const fs::path META_DIR = ".bh_meta";

namespace bithorded {
	namespace source {
		log4cplus::Logger log = log4cplus::Logger::getInstance("source");
	}
}

Store::Store(GrandCentralDispatch& gcd, const string label, const boost::filesystem::path& baseDir) :
	bithorded::store::AssetStore(baseDir.empty() ? fs::path() : (baseDir/META_DIR)),
	_gcd(gcd),
	_label(label),
	_baseDir(baseDir)
{
	if (!fs::exists(_baseDir))
		throw ios_base::failure("LinkedAssetStore: baseDir does not exist");
	AssetStore::openOrCreate();
}

void Store::describe(management::Info& target) const
{
	target << _baseDir << ": " << (store::AssetStore::size()/(1024*1024)) << "MB";
}

void Store::inspect(management::InfoList& target) const
{
	target.append("path") << _baseDir;
	target.append("size") << store::AssetStore::size();
}

const string& Store::label() const
{
	return _label;
}

bool path_is_in(const fs::path& path, const fs::path& folder) {
	string path_(fs::absolute(path).string());
	string folder_(fs::absolute(folder).string()+'/');
	return boost::starts_with(path_, folder_);
}

UpstreamRequestBinding::Ptr Store::addAsset(const boost::filesystem::path& file)
{
	if (path_is_in(file, _baseDir)) {
		fs::path assetFolder(AssetStore::newAssetDir());

		try {
			fs::create_relative_symlink(file, assetFolder/"data");
			SourceAsset::Ptr asset = boost::make_shared<SourceAsset>(_gcd, assetFolder);
			asset->status.onChange.connect(boost::bind(&Store::_addAsset, this, SourceAsset::WeakPtr(asset)));
			asset->hash();
			return boost::make_shared<UpstreamRequestBinding>(asset);
		} catch (const std::ios::failure& e) {
			LOG4CPLUS_ERROR(log, "Failed to create " << assetFolder << " for hashing " << file << ". Purging...");
			AssetStore::removeAsset(assetFolder);
			return UpstreamRequestBinding::NONE;
		}
	} else {
		return UpstreamRequestBinding::NONE;
	}
}

UpstreamRequestBinding::Ptr Store::findAsset(const bithorde::BindRead& req)
{
	return AssetSessions::findAsset(req);
}

void Store::_addAsset(SourceAsset::WeakPtr asset_)
{
	auto asset = asset_.lock();
	if (asset && asset->status->ids_size()) {
		auto data_path(asset->folder()/"data");
		lutimes(data_path.c_str(), NULL);

		AssetStore::update_links(asset->status->ids(), asset);
	}
}


IAsset::Ptr Store::openAsset(const boost::filesystem::path& assetPath)
{
	auto asset = boost::make_shared<SourceAsset>(_gcd, assetPath);
	if (asset->hasRootHash()) {
		return asset;
	} else {
		LOG4CPLUS_WARN(log, "Unhashed asset detected, hashing");
		asset->status.onChange.connect(boost::bind(&Store::_addAsset, this, SourceAsset::WeakPtr(asset)));
		asset->hash();
		return store::StoredAsset::Ptr();
	}
}
