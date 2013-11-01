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


#ifndef BITHORDED_GRANDCENTRALDISPATCH_HPP
#define BITHORDED_GRANDCENTRALDISPATCH_HPP

#include <boost/asio/io_service.hpp>
#include <boost/bind.hpp>
#include <boost/bind/protect.hpp>
#include <boost/thread.hpp>

namespace bithorded {

/**
 * The Grand Central Dispatch is a scheme to avoid blocking processing in the mainloop,
 * and to utilize parallelism in a controlled manner. Jobs sent to the GCD is assumed to
 * be const, and have no locking or other threading-issues.
 */
class GrandCentralDispatch : boost::noncopyable
{
	boost::asio::io_service& _controller;
	boost::asio::io_service _jobService;
	boost::asio::io_service::work _work;
	boost::thread_group _workers;
public:
	GrandCentralDispatch(boost::asio::io_service& controller, int parallel);
	virtual ~GrandCentralDispatch();

	boost::asio::io_service& ioService() const { return _controller; }

	template<typename Job, typename CompletionHandler>
	void submit(Job job, CompletionHandler handler) {
		typedef boost::_bi::protected_bind_t<Job> ProtectedJob;
		typedef boost::_bi::protected_bind_t<CompletionHandler> ProtectedCompletionHandler;
		_jobService.post(boost::bind(&GrandCentralDispatch::run_job<ProtectedJob, ProtectedCompletionHandler>, this, boost::protect(job), boost::protect(handler)));
	}

	template<typename Job, typename CompletionHandler>
	void run_job(Job job, CompletionHandler handler) {
		auto res = job();
		_controller.post(boost::bind(handler, res));
	}
};

}

#endif // BITHORDED_GRANDCENTRALDISPATCH_HPP
