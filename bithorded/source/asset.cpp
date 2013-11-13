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


#include "asset.hpp"

#include <boost/make_shared.hpp>
#include <boost/filesystem.hpp>

#include "../lib/relativepath.hpp"

using namespace std;
namespace fs = boost::filesystem;

using namespace bithorded;
using namespace bithorded::source;
using namespace bithorded::store;

SourceAsset::SourceAsset( GrandCentralDispatch& gcd, const string& id, const store::HashStore::Ptr& hashStore, const IDataArray::Ptr& data ) :
	StoredAsset(gcd, id, hashStore, data)
{
	auto trx = status.change();
	trx->set_status(bithorde::SUCCESS);
}

void SourceAsset::inspect(management::InfoList& target) const
{
	target.append("type") << "SourceAsset";
	target.append("path") << _data->describe();
}

void SourceAsset::apply(const AssetRequestParameters& old_parameters, const AssetRequestParameters& new_parameters)
{}

void SourceAsset::hash()
{
	notifyValidRange(0, size());
}

SourceAsset::Ptr SourceAsset::open ( GrandCentralDispatch& gcd, const boost::filesystem::path& path ) {
	HashStore::Ptr hashStore;
	IDataArray::Ptr dataStore;

	if (bithorded::store::openAsset(path, hashStore, dataStore)) {
		return boost::make_shared<SourceAsset>(gcd, path.filename().native(), hashStore, dataStore);
	}
	return SourceAsset::Ptr();
}

SourceAsset::Ptr SourceAsset::link ( GrandCentralDispatch& gcd, const boost::filesystem::path& assetFolder, const boost::filesystem::path& target ) {
	fs::create_relative_symlink(target, assetFolder/"data");

	IDataArray::Ptr dataStore = boost::make_shared<RandomAccessFile>(assetFolder/"data", RandomAccessFile::READ);
	HashStore::Ptr hashStore = createMetaFile(assetFolder, dataStore->size());

	auto ptr = boost::make_shared<SourceAsset>(gcd, assetFolder.filename().native(), hashStore, dataStore);
	ptr->status.change()->set_status(bithorde::SUCCESS);
	return ptr;
}

