/*
    Copyright 2012 Ulrik Mikaelsson <ulrik.mikaelsson@gmail.com>

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


#ifndef BITHORDED_CONFIG_HPP
#define BITHORDED_CONFIG_HPP

#include <boost/asio/ip/address.hpp>

#include <map>
#include <string>

namespace bithorded {

class ArgumentError : public std::exception {
public:
	ArgumentError(std::string m) : _msg(m) {}
	~ArgumentError() throw() {}
	const char* what() const throw() { return _msg.c_str(); }

private:
	std::string _msg;
};

struct Config
{
	Config(int argc, char* argv[]);

	static void print_usage(std::ostream& stream);

	std::string configPath;

	std::string nodeName;

	uint16_t tcpPort;
	std::string unixSocket;

	std::vector<std::string> linkroots;
};

}
#endif // CONFIG_HPP
