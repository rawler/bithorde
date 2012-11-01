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
#include "../lib/threadpool.hpp"
#include "../store/assetstore.hpp"

namespace bithorded {
	namespace source {

class Store
{
	ThreadPool _threadPool;
	boost::asio::io_service& _ioSvc;
	boost::filesystem::path _baseDir;
	bithorded::store::AssetStore _store;
	std::map<std::string, SourceAsset::WeakPtr> _tigerMap;
public:
	Store(boost::asio::io_service& ioSvc, const boost::filesystem::path& baseDir);

	/**
	 * Add an asset to the idx, creating a hash in the background. When hashing is done,
	 * the status of the asset will be updated to reflect it.
	 *
	 * If function returns true, /handler/ will be called on a thread running ioSvc.run()
	 *
	 * @returns a valid asset if file is within acceptable path, NULL otherwise
	 */
	IAsset::Ptr addAsset(const boost::filesystem3::path& file);

	/**
	 * Finds an asset by bithorde HashId. (Only the tiger-hash is actually used)
	 */
	IAsset::Ptr findAsset(const BitHordeIds& ids);
private:
	SourceAsset::Ptr _openTiger(const std::string& tigerId);
	void _addAsset( bithorded::source::SourceAsset* asset);
};

	}
}
#endif // BITHORDED_SOURCE_STORE_HPP
