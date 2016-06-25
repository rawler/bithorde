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


#ifndef COUNTER_H
#define COUNTER_H

#include "timer.h"

#include <ostream>

class TypedValue {
protected:
	uint64_t _value;
public:
	const std::string unit;
	TypedValue(const std::string& unit);
	virtual uint64_t value() const;
	TypedValue autoScale() const;
};

class Counter : public TypedValue
{
public:
	Counter(const std::string& unit);
	uint64_t operator+=(uint64_t amount);
	/**
	 * Returns: value before reset
	 */
	uint64_t reset();
};

class InertialValue : public TypedValue {
	float _inertia; // How much is the current data wheighted
	const std::string unit;
public:
	InertialValue(float inertia, const std::string& unit);
	uint64_t post(uint64_t amount);
};

class LazyCounter : public Counter
{
	PeriodicTimer _timer;
	InertialValue _value;
public:
	LazyCounter(TimerService& ts, const std::string& unit, const boost::posix_time::time_duration& granularity, float falloff);
	virtual uint64_t value() const;
private:
	void tick();
};

std::ostream& operator<<(std::ostream& tgt, const TypedValue& c);

#endif // COUNTER_H
