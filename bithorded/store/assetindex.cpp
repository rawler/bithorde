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
#include <limits>
#include <map>
#include <numeric>
#include <boost/range/adaptor/map.hpp>

#include "../../lib/hashes.h"

#include "../lib/management.hpp"

using namespace std;
using namespace bithorded;
using namespace bithorded::store;

AssetIndexEntry::AssetIndexEntry(
	const std::string& assetId,
	const BinId& tigerId,
	uint64_t diskUsage,
    uint64_t diskAllocation,
	double score) :
	_assetId(assetId),
	_tigerId(tigerId),
	_diskUsage(diskUsage),
    _diskAllocation(diskAllocation),
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

uint64_t AssetIndexEntry::diskUsage() const {
    return _diskUsage;
}

AssetIndexEntry& AssetIndexEntry::diskUsage(uint64_t newSize) {
	_diskUsage = newSize;
	return *this;
}

uint64_t AssetIndexEntry::diskAllocation() const {
    return _diskAllocation;
}

uint AssetIndexEntry::fillPercent() const {
    uint res;
    if (_diskAllocation)
        res = (_diskUsage * 100) / _diskAllocation;
    else
        res = std::numeric_limits<uint>::max();
    return std::min(res, static_cast<uint>(100));
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

/***** AssetIndex *****/

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
        target.append("urn:tree:tiger:" + asset->tigerId().base32()) << std::fixed << std::setprecision(1) << (kv.first-lowest) << '\t' << asset->diskUsage() << '\t' << asset->fillPercent() << '%';
    }
}

size_t AssetIndex::assetCount() const {
    return _assetMap.size();
}

void AssetIndex::addAsset(const std::string& assetId, const BinId& tigerId, uint64_t diskUsage, uint64_t diskAllocation, double score) {
    auto ptr = new AssetIndexEntry(assetId, tigerId, diskUsage, diskAllocation, score);
    auto& slot = _assetMap[assetId];
    if (slot) {
        _tigerMap.erase(slot->tigerId());
    }
    slot = std::unique_ptr<AssetIndexEntry>(ptr);
    if (!tigerId.empty()) {
        _tigerMap[tigerId] = ptr;
    }
}

/** Returns the tigerId the asset had, if any. */
BinId AssetIndex::removeAsset(const std::string& assetId) {
    BinId tigerId;
    auto iter = _assetMap.find(assetId);
    if ( iter != _assetMap.end() ) {
        tigerId = iter->second->tigerId();
        _tigerMap.erase(tigerId);
        _assetMap.erase(iter);
    }
    return tigerId;
}

double AssetIndex::updateAsset(const std::string& assetId, uint64_t diskUsage) {
    auto iter = _assetMap.find(assetId);
    if ( iter != _assetMap.end() ) {
        auto& assetPtr = iter->second;
        auto oldSize = assetPtr->diskUsage();
        if (diskUsage == 0) {
            diskUsage = oldSize;
        }
        auto diff = oldSize - diskUsage;
        auto addition = static_cast<float>(diff) / diskUsage;
        addition = std::max(addition, 0.01f);
        addition = std::min(addition, 0.5f);
        return assetPtr->addScore(addition);
    } else {
        return 0.0f;
    }
}

uint64_t AssetIndex::totalDiskUsage() const {
    uint64_t result = 0;
    for (auto& kv : _assetMap) {
        result += kv.second->diskUsage();
    }
    return result;
}

uint64_t AssetIndex::totalDiskAllocation() const {
    uint64_t result = 0;
    for (auto& kv : _assetMap) {
        result += kv.second->diskAllocation();
    }
    return result;
}

/** Returns assetId for asset */
std::string AssetIndex::lookupTiger( const BinId& tigerId ) const {
    auto res = _tigerMap.find(tigerId);
    if ( res != _tigerMap.end() ) {
        return res->second->assetId();
    } else {
        return std::string();
    }
}

/** Returns tigerId for asset */
const BinId& AssetIndex::lookupAsset( const std::string& assetId ) const {
    auto res = _assetMap.find(assetId);
    if ( res != _assetMap.end() ) {
        return res->second->tigerId();
    } else {
        return BinId::EMPTY;
    }
}

/** Returns the assetId for the asset in index with lowest score*/
std::string AssetIndex::pickLooser() const {
    std::string resultId;
    double resultScore = std::numeric_limits<float>::max();
    for (auto& kv : _assetMap) {
        const auto& entry = kv.second;
        if (entry->score() < resultScore) {
            resultScore = entry->score();
            resultId = entry->assetId();
        }
    }
    return resultId;
}
