/*
    Copyright 2013 Ulrik Mikaelsson <email>

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

#include "loopfilter.hpp"
#include <unordered_set>
#include <queue>

namespace bithorded {

const std::size_t LOOP_MEMORY = 131072;

class LoopFilterImpl {
	std::unordered_set<UUID> _set;
	std::queue<UUID> _queue;
public:
	bool test_and_set(UUID uuid) {
		if (_set.count(uuid)) {
			return false;
		} else {
			if (_queue.size() >= LOOP_MEMORY) {
				const auto& victim = _queue.front();
				_set.erase(victim);
				_queue.pop();
			}
			_set.insert(uuid);
			_queue.push(uuid);
			return true;
		}
	}
};

LoopFilter::LoopFilter() :
	_impl(new LoopFilterImpl)
{}

LoopFilter::~LoopFilter()
{
	delete _impl;
}

bool LoopFilter::test_and_set(UUID uuid)
{
	return _impl->test_and_set(uuid);
}

}