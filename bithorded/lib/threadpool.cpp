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

#include "threadpool.hpp"

#include <boost/thread.hpp>

using namespace std;

typedef boost::lock_guard<boost::mutex> mutex_guard;

ThreadPool::ThreadPool(int maxThreads) :
	_running(true),
	_m(),
	_maxThreads(maxThreads),
	_threads(),
	_tasks()
{
}

void ThreadPool::post(Task& task)
{
	mutex_guard m(_m);

	_tasks.push(&task);
	if (!_running)
		return;
	size_t threads = _threads.size();
	if ((threads < _maxThreads) && (threads < _tasks.size())) {
		auto thread = new boost::thread(boost::bind(&ThreadPool::thread_main, this));
		_threads[thread->get_id()] = thread;
	}
}

void ThreadPool::join()
{
	_running = false;
	while (size_t workers = workerCount())
		boost::this_thread::sleep(boost::posix_time::milliseconds(10*workers));
}

size_t ThreadPool::workerCount()
{
	mutex_guard m(_m);
	return _threads.size();
}

void ThreadPool::thread_main()
{
	while (Task* t = getTask()) {
		(*t)();
	}

	mutex_guard m(_m);
	auto id = boost::this_thread::get_id();
	auto thread = _threads[id];
	_threads.erase(id);
	delete thread;
}

Task* ThreadPool::getTask()
{
	mutex_guard m(_m);
	Task* res = NULL;
	if (!_tasks.empty()) {
		res = _tasks.front();
		_tasks.pop();
	}
	return res;
}

TaskQueue::TaskQueue(ThreadPool& pool)
	: Task(), _pool(pool), _running(false)
{

}

void TaskQueue::operator()()
{
	Task* task = getTask();

	(*task)();

	mutex_guard m(_m);
	if (_tasks.empty())
		_running = false;
	else
		_pool.post(*this);
}

void TaskQueue::enqueue(Task& task)
{
	mutex_guard m(_m);
	_tasks.push(&task);
	if (!_running) {
		_running = true;
		_pool.post(*this);
	}
}

Task* TaskQueue::getTask()
{
	mutex_guard m(_m);
	Task* res = NULL;
	if (!_tasks.empty()) {
		res = _tasks.front();
		_tasks.pop();
	}
	return res;
}
