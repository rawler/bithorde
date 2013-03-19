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


#ifndef COUNTER_H
#define COUNTER_H

#include "timer.h"

#include <ostream>

class Counter
{
protected:
	uint64_t _counter;
public:
	const std::string unit;

	Counter(const std::string& unit);
	uint64_t operator+=(uint64_t amount);
	void reset();
	virtual uint64_t value() const;
};

class LazyCounter : public Counter
{
	PeriodicTimer _timer;
	uint64_t _current;
	float _falloff; // How much is the current data wheighted
public:
	LazyCounter(TimerService& ts, const std::string& unit, const boost::posix_time::time_duration& granularity, float falloff);
	virtual uint64_t value() const;
private:
	void tick();
};

std::ostream& operator<<(std::ostream& tgt, const Counter& c);

#endif // COUNTER_H
