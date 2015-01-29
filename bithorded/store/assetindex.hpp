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
#ifndef BITHORDED_STORE_ASSETINDEX_HPP
#define BITHORDED_STORE_ASSETINDEX_HPP

#include <algorithm>
#include <limits>
#include <memory>
#include <string>
#include <unordered_map>

#include "../../lib/hashes.h"

namespace bithorded {
    namespace management {
        struct InfoList;
    }

namespace store {

class AssetIndexEntry {
    std::string _assetId;
    BinId _tigerId;
    uint64_t _diskUsage;
    uint64_t _diskAllocation;
    double _score;
public:
    AssetIndexEntry(const std::string& assetId, const BinId& tigerId, uint64_t diskUsage, uint64_t diskAllocation, double score);

    const std::string& assetId() const;
    const BinId& tigerId() const;
    AssetIndexEntry& tigerId(const BinId& newTigerId);

    uint64_t diskUsage() const;
    AssetIndexEntry& diskUsage(uint64_t newSize);
    uint64_t diskAllocation() const;

    uint fillPercent() const;

    double score() const;
    double addScore(float amount);
};

class AssetIndex {
    std::unordered_map<std::string, std::unique_ptr<AssetIndexEntry>> _assetMap;
    std::unordered_map<BinId, AssetIndexEntry*> _tigerMap;
public:
    void inspect(management::InfoList& target) const;

    size_t assetCount() const;

    void addAsset(const std::string& assetId, const BinId& tigerId, uint64_t diskUsage, uint64_t diskAllocation, double score);

    /** Returns the tigerId the asset had, if any. */
    BinId removeAsset(const std::string& assetId);

    double updateAsset(const std::string& assetId, uint64_t diskUsage);

    uint64_t totalDiskUsage() const;
    uint64_t totalDiskAllocation() const;

    /** Returns assetId for asset */
    std::string lookupTiger( const BinId& tigerId ) const;

    /** Returns tigerId for asset */
    const BinId& lookupAsset( const std::string& assetId ) const;

    /** Returns the assetId for the asset in index with lowest score*/
    std::string pickLooser() const;
};

}

}

#endif //BITHORDED_STORE_ASSETINDEX_HPP