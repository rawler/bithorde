/*
    Copyright 2012 Ulrik Mikaelsson <email>

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

#include "assetindex.hpp"

#include <chrono>
#include <iomanip>
#include <iostream>
#include <map>
#include <boost/range/adaptor/map.hpp>

#include "../../lib/hashes.h"

#include "../lib/management.hpp"

using namespace std;
using namespace bithorded;
using namespace bithorded::store;

AssetIndexEntry::AssetIndexEntry(
	const std::string& assetId,
	const BinId& tigerId,
	uint64_t size,
	double score) :
	_assetId(assetId),
	_tigerId(tigerId),
	_size(size),
	_score(score)
{}

const std::string& AssetIndexEntry::assetId() const {
    return _assetId;
}

const BinId& AssetIndexEntry::tigerId() const {
	return _tigerId;
}

AssetIndexEntry& AssetIndexEntry::tigerId(const BinId& newTigerId) {
	_tigerId = newTigerId;
	return *this;
}

uint64_t AssetIndexEntry::size() const {
    return _size;
}

AssetIndexEntry& AssetIndexEntry::size(uint64_t newSize) {
	_size = newSize;
	return *this;
}

double AssetIndexEntry::score() const {
	return _score;
}

double AssetIndexEntry::addScore(float amount) {
	unsigned long milliseconds_since_epoch =
    std::chrono::system_clock::now().time_since_epoch() /
    std::chrono::milliseconds(1);
    double seconds_since_epoch = (milliseconds_since_epoch / 1000.0);
    _score += (seconds_since_epoch - _score) * amount;
    return _score;
}

void AssetIndex::inspect(management::InfoList& target) const
{
    std::multimap<double, AssetIndexEntry*> scoreMap;
    for (auto& asset : _assetMap | boost::adaptors::map_values ) {
        scoreMap.insert(std::pair<double, AssetIndexEntry*>(asset->score(), asset.get()));
    }
    if (scoreMap.empty()) {
        return;
    }
    auto lowest = scoreMap.begin()->first;
    for (auto& kv : scoreMap) {
        auto asset = kv.second;
        target.append("urn:tree:tiger:" + asset->tigerId().base32()) << std::fixed << std::setprecision(1) << (kv.first-lowest) << '\t' << asset->size();
    }
}
