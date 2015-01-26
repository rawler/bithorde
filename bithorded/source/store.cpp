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

#include "../lib/grandcentraldispatch.hpp"
#include "../lib/relativepath.hpp"

using namespace std;

namespace asio = boost::asio;
namespace bsys = boost::system;
namespace fs = boost::filesystem;

using namespace bithorded;
using namespace bithorded::source;
using namespace bithorded::store;

const fs::path META_DIR = ".bh_meta";

namespace bithorded {
	namespace source {
		log4cplus::Logger log = log4cplus::Logger::getInstance("source");
	}
}

Store::Store( GrandCentralDispatch& gcd, const string& label, const boost::filesystem::path& baseDir ) :
	bithorded::store::AssetStore(baseDir.empty() ? fs::path() : (baseDir/META_DIR)),
	_gcd(gcd),
	_label(label),
	_baseDir(fs::canonical(baseDir))
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
	return AssetStore::inspect(target);
}

const string& Store::label() const
{
	return _label;
}

SourceAsset::Ptr Store::addAsset ( const boost::filesystem::path& file )
{
	auto target = fs::canonical( file );
	if (fs::path_is_in(target, _baseDir)) {
		auto assetPath(AssetStore::newAsset());
		auto relativepath = fs::relative(target, _baseDir).native();

		try {
			auto asset_data = boost::make_shared<RandomAccessFile>(target);

			auto meta = store::createAssetMeta(assetPath, store::V2LINKED, asset_data->size(), store::DEFAULT_HASH_LEVELS_SKIPPED, relativepath.size());
			meta.tail->write(0, relativepath);

			auto asset = boost::make_shared<SourceAsset>(_gcd, assetPath.filename().native(), meta.hashStore, asset_data);
			{
				asset->status.change()->set_status(bithorde::SUCCESS);
			}

			asset->status.onChange.connect(boost::bind(&Store::_addAsset, this, SourceAsset::WeakPtr(asset)));
			asset->hash();
			return asset;
		} catch (const std::ios::failure& e) {
			LOG4CPLUS_ERROR(log, "Failed to create " << assetPath << " for hashing " << file << ". Purging...");
			AssetStore::removeAsset(assetPath);
			return SourceAsset::Ptr();
		}
	} else {
		return SourceAsset::Ptr();
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
		AssetStore::update_asset(asset->status->ids(), asset);
	}
}

IAsset::Ptr Store::openAsset(const boost::filesystem::path& assetPath)
{
	AssetMeta meta;
	fs::path dataPath;

	switch (fs::status(assetPath).type()) {
	case boost::filesystem::directory_file:
		meta = store::openV1AssetMeta(assetPath/"meta");
		dataPath = fs::canonical(assetPath/"data", assetPath);
		break;
	case boost::filesystem::regular_file:
		meta = store::openV2AssetMeta(assetPath);
		dataPath = fs::canonical(dataArrayToString(*meta.tail), _baseDir);
		break;
	case boost::filesystem::file_not_found:
		throw bsys::system_error(bsys::errc::make_error_code(bsys::errc::no_such_file_or_directory), "Missing asset-link detected");
	default:
		throw bsys::system_error(bsys::errc::make_error_code(bsys::errc::not_supported), "Asset of unknown type");
	}

	if ( fs::last_write_time(assetPath) < fs::last_write_time(dataPath) ) {
		LOG4CPLUS_INFO(log, "Stale asset detected, hashing");
		auto asset = addAsset(dataPath);
		asset->status.change()->set_status(bithorde::Status::NONE);
		return asset;
	}

	auto dataStore = boost::make_shared<RandomAccessFile>(dataPath);
	auto asset = boost::make_shared<SourceAsset>(_gcd, assetPath.filename().native(), meta.hashStore, dataStore);

	if (!asset->hasRootHash()) {
		LOG4CPLUS_WARN(log, "Unhashed asset detected, hashing");
		asset->status.onChange.connect(boost::bind(&Store::_addAsset, this, SourceAsset::WeakPtr(asset)));
		asset->hash();
		return store::StoredAsset::Ptr();
	}

	return asset;
}
