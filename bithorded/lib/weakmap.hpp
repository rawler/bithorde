/*
    Copyright 2013 <copyright holder> <email>

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


#ifndef WEAKMAP_HPP
#define WEAKMAP_HPP

#include <unordered_map>
#include <boost/weak_ptr.hpp>

namespace bithorded {

template <typename KeyType, typename LinkType>
class WeakMap
{
	std::unordered_map<KeyType, boost::weak_ptr<LinkType> > _map;
	uint _scrubThreshold; // Will automatically perform a complete scrubbing after this amount of changes
	uint _dirtiness; // The amount of changes made since last scrubbing
public:
	typedef boost::shared_ptr<LinkType> Link;
	WeakMap(int scrubThreshold=sizeof(KeyType) / 10000) :
		_scrubThreshold(scrubThreshold),
		_dirtiness(0)
	{}

	/**
	 * Clears all keys
	 */
	void clear() {
		_map.clear();
	}

	/**
	 * Clears the given key in map
	 */
	void clear(const KeyType& key) {
		_map.erase(key);
	}

	/**
	 * Fetch a key from the map.
	 * Returns: A valid Link if a link were added and is still active.
	 *          An invalid link otherwise.
	 */
	Link operator[](const KeyType& key) {
		auto iter = _map.find(key);
		if (iter == _map.end()) {
			return Link();
		} else {
			auto link = iter->second.lock();
			if (!link) {
				_map.erase(key);
			}
			return link;
		}
	}

	/**
	 * Walks through all links in the map, purging any found inactive ones.
	 */
	void scrub() {
		auto iter = _map.begin();
		auto end = _map.end();
		while (iter != end) {
			if (iter->second.lock())
				iter++;
			else
				iter = _map.erase(iter);
		}
		_dirtiness = 0;
	}

	/**
	 * Will store the provided link as a weak link, available through get.
	 */
	void set(const KeyType& key, const Link& link) {
		BOOST_ASSERT(link);
		_map[key] = link;
		if (++_dirtiness >= _scrubThreshold)
			scrub();
	}
};

}

#endif // WEAKMAP_HPP
