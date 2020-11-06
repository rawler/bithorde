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


#ifndef TIMER_H
#define TIMER_H

#include <boost/asio/deadline_timer.hpp>
#include <boost/core/noncopyable.hpp>
#include <functional>
#include <map>

class Timer;

class TimerService : public std::enable_shared_from_this<TimerService> {
friend class Timer;
	std::multimap<boost::posix_time::ptime, Timer*> _timers;
	boost::asio::deadline_timer _timer;
public:
	typedef std::shared_ptr<TimerService> Ptr;
	TimerService(boost::asio::io_context& ioCtx);
protected:
	void arm(boost::posix_time::ptime deadline, Timer* t);
	void clear(const Timer* t);
private:
	void enable();
	void invoke(boost::system::error_code ec);
};

class Timer : private boost::noncopyable
{
friend class TimerService;
public:
	typedef std::function<void (const boost::posix_time::ptime& now)> Target;
private:
	TimerService* _ts;
	Target _target;
public:
	Timer(TimerService& ts, const Target& target);

	Timer(const Timer& other);
	virtual ~Timer();
	Timer& operator=(const Timer& other);

	void arm(boost::posix_time::ptime deadline);
	void arm(boost::posix_time::time_duration in);
	void clear();
protected:
	virtual void invoke(const boost::posix_time::ptime& scheduled_at, const boost::posix_time::ptime& now);
};

class PeriodicTimer : public Timer {
	boost::posix_time::time_duration _interval;
public:
	PeriodicTimer(TimerService& ts, const Target& target, boost::posix_time::time_duration interval);
	void rearm(boost::posix_time::time_duration value);
protected:
	virtual void invoke(const boost::posix_time::ptime& scheduled_at, const boost::posix_time::ptime& now);
};

#endif // TIMER_H
