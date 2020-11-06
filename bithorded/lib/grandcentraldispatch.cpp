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


#include "grandcentraldispatch.hpp"

#include <functional>

using namespace bithorded;

GrandCentralDispatch::GrandCentralDispatch(boost::asio::io_context& controller, int parallel)
	: _controller(controller), _work(_jobService)
{
	for (int i = 0; i < parallel; ++i)
		_workers.create_thread([=]{_jobService.run();});
}

GrandCentralDispatch::~GrandCentralDispatch() {
	_jobService.stop();
	_workers.join_all();
}
