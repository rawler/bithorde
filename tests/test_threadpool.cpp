#include <boost/test/unit_test.hpp>
#include <boost/make_shared.hpp>
#include <boost/shared_ptr.hpp>
#include <stdlib.h>
#include <vector>

#include "bithorded/lib/threadpool.hpp"

using namespace std;

class MyTaskQueue : public TaskQueue {
public:
	MyTaskQueue(ThreadPool& tp) : TaskQueue(tp), running(0) {}
	int running;
};

class MyTask : public Task {
public:
	MyTask(MyTaskQueue &q) : _q(q) {}

	void operator()() {
		if (_q.running++ != 0)
			BOOST_FAIL("Seems to be more than one job per TaskQueue running.");
		usleep(0);
		if (_q.running-- != 1)
			BOOST_FAIL("Seems to be more than one job per TaskQueue running.");
		delete this;
	}
private:
	MyTaskQueue& _q;
};

BOOST_AUTO_TEST_CASE( threadpool_test )
{
	ThreadPool tp(11);

	vector< boost::shared_ptr<MyTaskQueue> > queues;

	for (auto i=0; i < 5; i++)
		queues.push_back( boost::make_shared<MyTaskQueue>(tp) );

	for (auto iter = queues.begin(); iter != queues.end(); iter++) {
		for (auto i = 0; i < 113; i++)
			(*iter)->enqueue(*(new MyTask(**iter)));
	}

	tp.join();
}
