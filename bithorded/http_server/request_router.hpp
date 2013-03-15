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

#ifndef HTTP_REQUEST_ROUTER_HPP
#define HTTP_REQUEST_ROUTER_HPP

#include "reply.hpp"
#include "request.hpp"

#include <boost/range/iterator_range.hpp>
#include <list>

#include "../lib/weakmap.hpp"

namespace http { namespace server {

class RequestRouter {
public:
	typedef std::string path_entry;
	typedef std::list<path_entry>::iterator path_entry_iterator;
	typedef boost::iterator_range<path_entry_iterator> path;
	virtual bool handle(const path& path, const request& req, reply& reply) const =0;
};

}}

#endif //HTTP_REQUEST_ROUTER_HPP