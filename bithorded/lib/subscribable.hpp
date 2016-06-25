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


#ifndef SUBSCRIBABLE_HPP
#define SUBSCRIBABLE_HPP

#include <boost/signals2/signal.hpp>

template <typename T>
class ChangeGuard{
	T* _data;
	const T _dataCopy;
	const boost::signals2::signal<void (const T&, const T&)>& _signal;
public:
	ChangeGuard(T* data, const boost::signals2::signal<void (const T&, const T&)>& signal)
		: _data(data), _dataCopy(*data), _signal(signal)
	{}
	virtual ~ChangeGuard() {
		if (_dataCopy != *_data)
			_signal(_dataCopy, *_data);
	}
	ChangeGuard<T>& operator=(const ChangeGuard<T>& other) {
		_data = other._data;
		_dataCopy = other._dataCopy;
		_signal = other._signal;
		return *this;
	}
	virtual T* get() {
		return _data;
	}
	virtual T* operator->() {
		return _data;
	}
	virtual T& operator*() {
		return *_data;
	}
};

template <typename T>
class Subscribable
{
	T _value;
public:
	boost::signals2::signal<void (const T&, const T&)> onChange;

	Subscribable() {}
	Subscribable( const Subscribable<T>& ) = delete;

	virtual ChangeGuard< T > change() {
		return ChangeGuard<T>(&_value, onChange);
	}

	Subscribable& operator=(const T& other) {
		auto guard = change();
		(*guard) = other;
		return *this;
	}

	virtual bool operator==(const T& other) const {
		return (_value) == other;
	}
	virtual bool operator==(const Subscribable< T >& other) const {
		return (_value) == (other._value);
	}

	virtual bool operator!=(const T& other) const {
		return (_value) != other;
	}
	virtual bool operator!=(const Subscribable< T >& other) const {
		return (_value) != (other._value);
	}

	virtual const T* get() const {
		return &_value;
	}

	virtual const T* operator->() const {
		return &_value;
	}

	virtual const T& operator*() const {
		return _value;
	}
};

#endif // SUBSCRIBABLE_HPP
