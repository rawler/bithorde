//
// request_handler.cpp
// ~~~~~~~~~~~~~~~~~~~
//
// Copyright (c) 2003-2012 Christopher M. Kohlhoff (chris at kohlhoff dot com)
//
// Distributed under the Boost Software License, Version 1.0. (See accompanying
// file LICENSE_1_0.txt or copy at http://www.boost.org/LICENSE_1_0.txt)
//

#include "request_handler.hpp"
#include <fstream>
#include <sstream>
#include <string>
#include <boost/lexical_cast.hpp>
#include <boost/algorithm/string.hpp>
#include "reply.hpp"
#include "request.hpp"

namespace http {
namespace server {

request_handler::request_handler(const RequestRouter& root)
  : _root(root)
{
}

void request_handler::handle_request(const request& req, reply& rep)
{
	// Decode url to path.
	std::list<std::string> request_path;
	boost::split(request_path, req.uri, boost::is_any_of("/"), boost::algorithm::token_compress_on).size();
	for (auto iter=request_path.begin(); iter != request_path.end(); iter++) {
		std::string tmp;
		url_decode(*iter, tmp);
		*iter = tmp;
	}

	if (!_root.handle(request_path, req, rep))
		rep = reply::stock_reply(reply::not_found);
}

bool request_handler::url_decode(const std::string& in, std::string& out)
{
	out.clear();
	out.reserve(in.size());
	for (std::size_t i = 0; i < in.size(); ++i) {
		if (in[i] == '%') {
			if (i + 3 <= in.size()) {
				int value = 0;
				std::istringstream is(in.substr(i + 1, 2));
				if (is >> std::hex >> value) {
					out += static_cast<char>(value);
					i += 2;
				} else {
					return false;
				}
			} else {
				return false;
			}
		} else if (in[i] == '+') {
			out += ' ';
		} else {
			out += in[i];
		}
	}
	return true;
}

} // namespace server
} // namespace http
