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


#include "managementnode.hpp"

#include <sstream>
#include <iostream>

using namespace std;

bithorded::ManagementInfo::ManagementInfo(const http::server::RequestRouter* child, const string& name) :
	child(child), name(name)
{}

bithorded::ManagementInfo::ManagementInfo(const bithorded::ManagementInfo& other) :
	std::stringstream(other.str()), child(other.child), name(other.name)
{}

bithorded::ManagementInfo& bithorded::ManagementInfo::operator=(const bithorded::ManagementInfo& other)
{
	std::stringstream(other.str());
	child = other.child;
	name = other.name;
	return *this;
}

std::ostream& bithorded::ManagementInfo::render_text(std::ostream& output) const
{
	if (child)
		output << "@";
	output << name << " : " << rdbuf() << '\n';
	return output;
}

ostream& bithorded::ManagementInfo::render_html(ostream& output) const
{
	output << "<tr><td>";
	if (child)
		output << "<a href=\"" << name << "/\">" << name << "</a>";
	else
		output << name;
	output << "</td><td>" << rdbuf() << "</td></tr>";
	return output;
}

bithorded::ManagementInfo& bithorded::ManagementInfoList::append(const http::server::RequestRouter* child, const string& name)
{
	push_back(ManagementInfo(child, name));
	return back();
}

bool bithorded::ManagementNode::handle(const http::server::RequestRouter::path& path, const http::server::request& req, http::server::reply& reply) const
{
	ManagementInfoList table;
	inspect(table);
	if (path.empty()) {
		std::ostringstream buf;
		bool html = req.accepts("text/html");
		if (html) {
			buf << "<html><head><title>Bithorde Management</title></head><body>"
				<< "<table><tr><th>Name</th><th>Value</th></tr>";
		}
		for (auto iter=table.begin(); iter != table.end(); iter++) {
			if (html)
				iter->render_html(buf);
			else
				iter->render_text(buf);
		}
		if (html) {
			buf << "</table></body></html>";
		}
		reply.fill(buf.str(), html ? "text/html" : "text/plain");
		return true;
	} else {
		auto node = path.begin();
		for (auto iter = table.begin(); iter != table.end(); iter++) {
			if (iter->child && (*node == iter->name))
				return iter->child->handle(http::server::RequestRouter::path(++node, path.end()), req, reply);
		}
	}
	return false;
}
