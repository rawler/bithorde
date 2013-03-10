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
#include <boost/thread/pthread/mutex.hpp>
#include <boost/thread/locks.hpp>
#include <boost/weak_ptr.hpp>

namespace bithorded {

template <typename KeyType, typename LinkType>
class WeakMap
{
	typedef boost::weak_ptr<LinkType> WeakPtr;
	std::unordered_map<KeyType, WeakPtr> _map;
	uint _scrubThreshold; // Will automatically perform a complete scrubbing after this amount of changes
	uint _dirtiness; // The amount of changes made since last scrubbing
	boost::mutex _m;
	typedef boost::lock_guard<boost::mutex> lock_guard;
public:
	typedef boost::shared_ptr<LinkType> Link;
	WeakMap(int scrubThreshold=sizeof(KeyType) / 10000) :
		_scrubThreshold(scrubThreshold),
		_dirtiness(0)
	{}

	typename std::unordered_map<KeyType, WeakPtr>::iterator begin() { return _map.begin(); }
	typename std::unordered_map<KeyType, WeakPtr>::const_iterator begin() const { return _map.begin(); }
	typename std::unordered_map<KeyType, WeakPtr>::iterator end() { return _map.end(); }
	typename std::unordered_map<KeyType, WeakPtr>::const_iterator end() const { return _map.end(); }

	/**
	 * Clears all keys
	 */
	void clear() {
		lock_guard lock(_m);
		_map.clear();
	}

	/**
	 * Clears the given key in map
	 */
	void clear(const KeyType& key) {
		lock_guard lock(_m);
		_map.erase(key);
	}

	/**
	 * Fetch a key from the map.
	 * Returns: A valid Link if a link were added and is still active.
	 *          An invalid link otherwise.
	 */
	Link operator[](const KeyType& key) {
		lock_guard lock(_m);
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
	 * Counts active link in map
	 */
	size_t size() const {
		size_t res = 0;
		for (auto iter=_map.begin(); iter != _map.end(); iter++) {
			if (iter->second.lock())
				res++;
		}
		return res;
	}

	/**
	 * Walks through all links in the map, purging any found inactive ones.
	 */
	size_t scrub() {
		lock_guard lock(_m);
		doScrub();
		return _map.size();
	}

	/**
	 * Will store the provided link as a weak link, available through get.
	 */
	void set(const KeyType& key, const Link& link) {
		lock_guard lock(_m);

		BOOST_ASSERT(link);
		_map[key] = link;
		if (++_dirtiness >= _scrubThreshold)
			doScrub();
	}
private:
	/**
	 * Caller MUST hold lock on _m.
	 */
	void doScrub() {
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
};

}

#endif // WEAKMAP_HPP
