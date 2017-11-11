/*
    Copyright 2016 Ulrik Mikaelsson <ulrik.mikaelsson@gmail.com>

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


#include "assetsessions.hpp"

#include "../../lib/hashes.h"

bithorded::UpstreamRequestBinding::Ptr bithorded::AssetSessions::findAsset(const bithorde::BindRead& req)
{
	auto tigerId = findBithordeId(req.ids(), bithorde::HashType::TREE_TIGER);
	if (tigerId.empty())
		return UpstreamRequestBinding::Ptr();
	if (auto active = _tigerCache[tigerId])
		return active;

	UpstreamRequestBinding::Ptr res;
	if (auto asset = openAsset(req)) {
		res = std::make_shared<UpstreamRequestBinding>(asset);
		add(tigerId, res);
	}
	return res;
}

void bithorded::AssetSessions::add(const bithorde::Id& tigerId, const UpstreamRequestBinding::Ptr& asset)
{
	if (asset)
		_tigerCache.set(tigerId, asset);
}


