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

#include "counter.h"

#include <boost/bind.hpp>

Counter::Counter(const std::string& unit)
	: unit(unit)
{
	reset();
}

uint64_t Counter::operator+=(uint64_t amount)
{
	return _counter += amount;
}

void Counter::reset()
{
	_counter = 0;
}

uint64_t Counter::value() const
{
	return _counter;
}

LazyCounter::LazyCounter(TimerService& ts, const std::string& unit, const boost::posix_time::time_duration& granularity, float falloff)
	: Counter(unit), _timer(ts, boost::bind(&LazyCounter::tick, this), granularity), _current(0), _falloff(falloff)
{
}

uint64_t LazyCounter::value() const
{
	return _current;
}

void LazyCounter::tick()
{
	_current = (_counter * _falloff) + (_current * (1.0-_falloff));
	reset();
}

std::ostream& operator<<(std::ostream& tgt, const Counter& c)
{
	auto value = c.value();
	char prefix(0);
	if (value >= 1000000000) { value /= 1000000000; prefix = 'G'; }
	if (value >= 1000000) { value /= 1000000; prefix = 'M'; }
	if (value >= 1000) { value /= 1000; prefix = 'K'; }
	tgt << value;
	if (prefix)
		tgt << prefix;
	tgt << c.unit;
	return tgt;
}
