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


#ifndef BITHORDED_SOURCE_ASSET_H
#define BITHORDED_SOURCE_ASSET_H

#include <boost/filesystem/path.hpp>
#include <boost/shared_ptr.hpp>

#include "../server/asset.hpp"
#include "../store/asset.hpp"

#include "bithorde.pb.h"

namespace bithorded {
	namespace source {

class SourceAsset : public store::StoredAsset
{
public:
	typedef boost::shared_ptr<SourceAsset> Ptr;
	typedef boost::weak_ptr<SourceAsset> WeakPtr;

	/**
	 * The /metaFolder/ is a special control-folder for a single-asset. It has file
	 *  "data" which is an actual data-file or symlink to the data-file, and
	 *  "meta" which holds info about blocks indexed, hashtree indexes etc.
	 */
	SourceAsset(bithorded::GrandCentralDispatch& gcd, const std::string& id, const store::HashStore::Ptr& hashStore, const bithorded::IDataArray::Ptr& data);

	virtual void inspect(management::InfoList& target) const;

	virtual void apply(const AssetRequestParameters& old_parameters, const AssetRequestParameters& new_parameters);

	/**
	 * Starts background job building a hashtree of the content in the asset
	 */
	void hash();

	static Ptr open( bithorded::GrandCentralDispatch& gcd, const boost::filesystem::path& path );
	static Ptr link( bithorded::GrandCentralDispatch& gcd, const boost::filesystem::path& path, const boost::filesystem::path& target );
};

	}
}
#endif // BITHORDED_SOURCE_ASSET_H
