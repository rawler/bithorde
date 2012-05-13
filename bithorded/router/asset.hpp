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

#ifndef BITHORDED_ROUTER_ASSET_H
#define BITHORDED_ROUTER_ASSET_H

#include <map>
#include <memory>

#include "../server/asset.hpp"
#include "../server/client.hpp"
#include "../../lib/asset.h"
#include "../../lib/client.h"

namespace bithorded {
namespace router {
class Router;

struct PendingRead {
	uint64_t offset;
	size_t size;
	Asset::ReadCallback cb;
};

class ForwardedAsset : public bithorded::Asset
{
	typedef bithorde::ReadAsset UpstreamAsset;

	Router& _router;
	BitHordeIds _ids;
	int64_t _size;
	std::map<std::string, std::unique_ptr<UpstreamAsset> > _upstream;
	std::list<PendingRead> _pendingReads;
public:
	typedef boost::shared_ptr<ForwardedAsset> Ptr;
	typedef boost::weak_ptr<ForwardedAsset> WeakPtr;

	ForwardedAsset(Router& router, const BitHordeIds& ids) :
		_router(router),
		_ids(ids),
		_size(-1),
		_upstream(),
		_pendingReads()
	{}

	bool hasUpstream(const std::string peername);
	void bindUpstreams(const std::map<std::string, Client::Ptr>& friends, uint64_t uuid);

	virtual size_t can_read(uint64_t offset, size_t size);
	virtual bool getIds(BitHordeIds& ids);
	virtual void async_read(uint64_t offset, size_t& size, ReadCallback cb);
	virtual uint64_t size();
private:
	void onUpstreamStatus(const std::string& peername, const bithorde::AssetStatus& status);
	void updateStatus();
	void onData(uint64_t offset, const std::string& data, int tag);
};

}
}

#endif // BITHORDED_ROUTER_ASSET_H
