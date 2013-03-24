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


#ifndef MANAGEMENT_HPP
#define MANAGEMENT_HPP

#include <sstream>

#include "../http_server/request_router.hpp"

namespace bithorded {

namespace management {

struct Info : public std::stringstream {
	const http::server::RequestRouter* child;
	std::string name;

	Info(const Info& other);
	Info(const http::server::RequestRouter* child, const std::string& name);

	Info& operator=(const Info& other);

	std::ostream& render_text(std::ostream& output) const;
	std::ostream& render_html(std::ostream& output) const;
};

class Leaf {
public:
	virtual void describe(Info& target) const = 0;
};

class DescriptiveDirectory;
struct InfoList : public std::vector<Info> {
	Info& append(const std::string& name, const http::server::RequestRouter* child=NULL, const Leaf* renderer=NULL);
	Info& append(const std::string& name, const DescriptiveDirectory& dir);
	Info& append(const std::string& name, const Leaf& leaf);
};

class Directory : public http::server::RequestRouter
{
public:
	virtual bool handle(const path& path, const http::server::request& req, http::server::reply& reply) const;
protected:
	virtual void inspect(InfoList& target) const = 0;
};

class DescriptiveDirectory : public Leaf, public Directory {};
}}

#endif // MANAGEMENT_HPP
