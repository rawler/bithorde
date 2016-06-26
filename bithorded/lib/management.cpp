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


#include "management.hpp"

#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>

using namespace std;

using namespace bithorded::management;

Info::Info(const http::server::RequestRouter* child, const string& name) :
	child(child), name(name)
{}

Info::Info(const Info& other) :
	std::stringstream(other.str()), child(other.child), name(other.name)
{}

Info& Info::operator=(const Info& other)
{
	std::stringstream(other.str());
	child = other.child;
	name = other.name;
	return *this;
}

std::ostream& Info::renderText(std::ostream& output) const
{
	if (child)
		output << "@";
	output << name << " : " << rdbuf() << '\n';
	return output;
}

ostream& Info::renderHTML(ostream& output) const
{
	output << "<tr><td>";
	if (child)
		output << "<a href=\"" << name << "/\">" << name << "</a>";
	else
		output << name;
	output << "</td><td>" << rdbuf() << "</td></tr>";
	return output;
}

std::string json_escape(const std::string& s) {
    std::stringstream ss;
    for (size_t i = 0; i < s.length(); ++i) {
        if (unsigned(s[i]) < '\x20' || s[i] == '\\' || s[i] == '"') {
            ss << "\\u" << std::setfill('0') << std::setw(4) << std::hex << unsigned(s[i]);
        } else {
            ss << s[i];
        }
    }
    return ss.str();
}

ostream& Info::renderJSON(ostream& output) const {
	output << '"' << json_escape(name) << "\":\"" << json_escape(str()) << '"';
	return output;
}

Info& InfoList::append(const string& name, const http::server::RequestRouter* child, const Leaf* renderer)
{
	push_back(Info(child, name));
	if (renderer)
		renderer->describe(back());
	return back();
}

Info& InfoList::append(const string& name, const DescriptiveDirectory& dir)
{
	return append(name, &dir, &dir);
}

Info& InfoList::append(const string& name, const Leaf& leaf)
{
	return append(name, NULL, &leaf);
}

ostream& InfoList::renderHTML(ostream& output) const {
	output << "<html><head><title>Bithorde Management</title></head><body>"
		<< "<table><tr><th>Name</th><th>Value</th></tr>";

	for (auto iter=begin(); iter != end(); iter++) {
		iter->renderHTML(output);
	}

	output << "</table></body></html>";
	return output;
}

ostream& InfoList::renderJSON(ostream& output) const {
	output << "{";
	for (auto iter=begin(); iter != end(); iter++) {
		if (iter != begin()) {
			output << ',';
		}
		iter->renderJSON(output);
	}
	output << "}";

	return output;
}

ostream& InfoList::renderText(ostream& output) const {
	for (auto iter=begin(); iter != end(); iter++) {
		iter->renderText(output);
	}

	return output;
}

bool Directory::handle(const http::server::RequestRouter::path& path, const http::server::request& req, http::server::reply& reply) const
{
	InfoList table;
	inspect(table);
	if (path.empty()) {
		std::ostringstream buf;
		std::string type;

		if (type = "application/json", req.accepts(type)) {
			table.renderJSON(buf);
		} else if (type = "text/html", req.accepts(type)) {
			table.renderHTML(buf);
		} else {
			type = "text/plain";
			table.renderText(buf);
		}

		reply.fill(buf.str(), type);
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
