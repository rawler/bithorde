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

namespace store {

class AssetIndexEntry {
    std::string _assetId;
    BinId _tigerId;
    uint64_t _size;
    double _score;
public:
    AssetIndexEntry(const std::string& assetId, const BinId& tigerId, uint64_t size, double score);

    const std::string& assetId() const;
    const BinId& tigerId() const;
    AssetIndexEntry& tigerId(const BinId& newTigerId);

    uint64_t size() const;
    AssetIndexEntry& size(uint64_t newSize);

    double score() const;
    double addScore(float amount);
};

class AssetIndex {
    std::unordered_map<std::string, std::unique_ptr<AssetIndexEntry>> _assetMap;
    std::unordered_map<BinId, AssetIndexEntry*> _tigerMap;
public:
    size_t assetCount() const {
        return _assetMap.size();
    }

    void addAsset(const std::string& assetId, const BinId& tigerId, uint64_t size, double score) {
        auto ptr = new AssetIndexEntry(assetId, tigerId, size, score);
        auto& slot = _assetMap[assetId];
        if (slot) {
            _tigerMap.erase(slot->tigerId());
        }
        slot = std::unique_ptr<AssetIndexEntry>(ptr);
        if (!tigerId.empty()) {
            _tigerMap[tigerId] = ptr;
        }
    }

    void removeAsset(const std::string& assetId) {
        auto iter = _assetMap.find(assetId);
        if ( iter != _assetMap.end() ) {
            _tigerMap.erase(iter->second->tigerId());
            _assetMap.erase(iter);
        }
    }

    double updateAsset(const std::string& assetId, uint64_t size) {
        auto iter = _assetMap.find(assetId);
        if ( iter != _assetMap.end() ) {
            auto& assetPtr = iter->second;
            auto oldSize = assetPtr->size();
            if (size == 0) {
                size = oldSize;
            }
            auto diff = oldSize - size;
            auto addition = static_cast<float>(diff) / size;
            addition = std::max(addition, 0.01f);
            addition = std::min(addition, 0.5f);
            return assetPtr->addScore(addition);
        } else {
            return 0.0f;
        }
    }

    uint64_t totalSize() const {
        uint64_t result = 0;
        for (auto& kv : _assetMap) {
            result += kv.second->size();
        }
        return result;
    }

    /** Returns assetId for asset */
    std::string lookupTiger( const BinId& tigerId ) const {
        auto res = _tigerMap.find(tigerId);
        if ( res != _tigerMap.end() ) {
            return res->second->assetId();
        } else {
            return std::string();
        }
    }

    /** Returns tigerId for asset */
    const BinId& lookupAsset( const std::string& assetId ) const {
        auto res = _assetMap.find(assetId);
        if ( res != _assetMap.end() ) {
            return res->second->tigerId();
        } else {
            return BinId::EMPTY;
        }
    }

    /** Returns the assetId for the asset in index with lowest score*/
    std::string findVictim() const {
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
};

}

}

#endif //BITHORDED_STORE_ASSETINDEX_HPP