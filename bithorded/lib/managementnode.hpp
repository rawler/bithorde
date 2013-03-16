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


#ifndef MANAGEMENTNODE_HPP
#define MANAGEMENTNODE_HPP

#include <sstream>

#include "../http_server/request_router.hpp"

namespace bithorded {

struct ManagementInfo : public std::stringstream {
	const http::server::RequestRouter* child;
	std::string name;

	ManagementInfo(const ManagementInfo& other);
	ManagementInfo(const http::server::RequestRouter* child, const std::string& name);

	ManagementInfo& operator=(const ManagementInfo& other);

	std::ostream& render_text(std::ostream& output) const;
	std::ostream& render_html(std::ostream& output) const;
};

struct ManagementInfoList : public std::vector<ManagementInfo> {
	ManagementInfo& append(const http::server::RequestRouter* child, const std::string& name);
};

class ManagementNode : public http::server::RequestRouter
{
public:
	virtual bool handle(const path& path, const http::server::request& req, http::server::reply& reply) const;
protected:
	virtual void inspect(ManagementInfoList& target) const = 0;
};

}

#endif // MANAGEMENTNODE_HPP
