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

#include "counter.h"

#include <functional>

TypedValue::TypedValue(const std::string& unit)
	: _value(0), unit(unit)
{}

uint64_t TypedValue::value() const
{
	return _value;
}

TypedValue TypedValue::autoScale() const
{
	std::string prefix;
	auto value_ = value();
	if (value_ >= 10*1000*1000*1000LL) { value_ /= 1000000000; prefix = 'G'; }
	if (value_ >= 10*1000*1000) { value_ /= 1000000; prefix = 'M'; }
	if (value_ >= 10*1000) { value_ /= 1000; prefix = 'K'; }
	TypedValue res(prefix+unit);
	res._value = value_;
	return res;
}

Counter::Counter(const std::string& unit)
	: TypedValue(unit)
{}

uint64_t Counter::operator+=(uint64_t amount)
{
	return _value += amount;
}

uint64_t Counter::reset()
{
	auto res = _value;
	_value = 0;
	return res;
}

InertialValue::InertialValue(float inertia, const std::string& unit)
	: TypedValue(unit), _inertia(inertia)
{}

uint64_t InertialValue::post(uint64_t amount)
{
	return _value = (amount * (1.0-_inertia)) + (_value * (_inertia));
}

LazyCounter::LazyCounter(TimerService& ts, const std::string& unit, const boost::posix_time::time_duration& granularity, float falloff)
	: Counter(unit), _timer(ts, std::bind(&LazyCounter::tick, this), granularity), _value(falloff, unit)
{
}

uint64_t LazyCounter::value() const
{
	return _value.value();
}

void LazyCounter::tick()
{
	_value.post(reset());
}

std::ostream& operator<<(std::ostream& tgt, const TypedValue& v)
{
	tgt << v.value() << v.unit;
	return tgt;
}
