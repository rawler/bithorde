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


#ifndef BITHORDED_SOURCE_STORE_HPP
#define BITHORDED_SOURCE_STORE_HPP

#include <boost/asio/io_service.hpp>
#include <boost/filesystem/path.hpp>
#include <boost/function.hpp>
#include <map>

#include "asset.hpp"
#include "bithorde.pb.h"
#include "../lib/management.hpp"
#include "../lib/weakmap.hpp"
#include "../store/assetstore.hpp"

namespace bithorded {
	namespace source {

class Store : private bithorded::store::AssetStore, public bithorded::management::DescriptiveDirectory
{
	GrandCentralDispatch& _gcd;
	std::string _label;
	boost::filesystem::path _baseDir;
public:
	Store(GrandCentralDispatch& gcd, const std::string& label, const boost::filesystem::path& baseDir);

	virtual void describe(management::Info& target) const;
	virtual void inspect(management::InfoList& target) const;

	const std::string& label() const;

	/**
	 * Add an asset to the idx, creating a hash in the background. When hashing is done,
	 * the status of the asset will be updated to reflect it.
	 *
	 * If function returns true, /handler/ will be called on a thread running ioSvc.run()
	 *
	 * @returns a valid asset if file is within acceptable path, NULL otherwise
	 */
	SourceAsset::Ptr addAsset(const boost::filesystem::path& file);

	/**
	 * Finds an asset by bithorde HashId. (Only the tiger-hash is actually used)
	 */
	UpstreamRequestBinding::Ptr findAsset(const bithorde::BindRead& req);

	IAsset::Ptr openAsset(const boost::filesystem::path& assetPath);
private:
	void _addAsset( bithorded::source::SourceAsset::WeakPtr asset);
};

	}
}
#endif // BITHORDED_SOURCE_STORE_HPP
