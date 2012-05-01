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


#ifndef BITHORDED_LINKEDASSETSTORE_HPP
#define BITHORDED_LINKEDASSETSTORE_HPP

#include <boost/asio/io_service.hpp>
#include <boost/filesystem/path.hpp>
#include <boost/function.hpp>
#include <map>

#include "sourceasset.hpp"
#include "bithorde.pb.h"
#include "../lib/threadpool.hpp"

namespace bithorded {

typedef google::protobuf::RepeatedPtrField< bithorde::Identifier > BitHordeIds;

class LinkedAssetStore
{
	ThreadPool _threadPool;
	boost::asio::io_service& _ioSvc;
	boost::filesystem::path _baseDir;
	boost::filesystem::path _assetsFolder;
	boost::filesystem::path _tigerFolder;
	std::map<std::string, SourceAsset::WeakPtr> _tigerMap;
public:
	typedef boost::function< void ( SourceAsset::Ptr )> ResultHandler;
	
	LinkedAssetStore(boost::asio::io_service& ioSvc, const boost::filesystem::path& baseDir);

	/**
	 * Add an asset to the idx, creating a hash in the background. When hashing is done,
	 * responder will be called asynchronously.
	 *
	 * In responder, the shared_ptr will be set to either a readily hashed instance, or empty if hashing failed
	 *
	 * If function returns true, /handler/ will be called on a thread running ioSvc.run()
	 *
	 * @returns true if file is within acceptable path, false otherwise
	 */
	bool addAsset(const boost::filesystem::path& file, ResultHandler handler);

	/**
	 * Finds an asset by bithorde HashId. (Only the tiger-hash is actually used)
	 */
	Asset::Ptr findAsset(const BitHordeIds& ids);

private:
	SourceAsset::Ptr _openTiger(const std::string& tigerId);
	void _addAsset( bithorded::SourceAsset::Ptr& asset, bithorded::LinkedAssetStore::ResultHandler upstream);
};

}
#endif // BITHORDED_LINKEDASSETSTORE_HPP
