/*
    Copyright 2012 <copyright holder> <email>

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


#ifndef THREADPOOL_HPP
#define THREADPOOL_HPP

#include <boost/thread/mutex.hpp>
#include <boost/thread/thread.hpp>
#include <queue>

class Task {
public:
	virtual void operator()() = 0;
};

class ThreadPool
{
public:
	ThreadPool(int maxThreads);

	void post(Task& task);

	void join();
private:
	void thread_main();
	Task* getTask();

	bool _running;
	boost::mutex _m;
	uint _maxThreads;
	boost::thread_group _threads;
	std::queue<Task*> _tasks;
};

class TaskQueue : public Task {
public:
	TaskQueue(ThreadPool &pool);

	void enqueue(Task& task);

	void operator()();
private:
	Task* getTask();

	ThreadPool& _pool;
	bool _running;
	boost::mutex _m;
	std::queue<Task*> _tasks;
};

#endif // THREADPOOL_HPP
