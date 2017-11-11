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


#ifndef BITHORDED_CONFIG_HPP
#define BITHORDED_CONFIG_HPP

#include <boost/asio/ip/address.hpp>
#include <boost/filesystem/path.hpp>
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

// Special Exception to hint at version-printing.
class VersionExit : public std::exception {};

struct Config
{
	struct Source {
		std::string name;
		boost::filesystem::path root;
	};

	struct Client {
		Client();
		std::string name;
		enum CipherType {
			CLEARTEXT = 0,
			XOR = 1,
			RC4 = 2,
			AES_CTR = 3
		} cipher;
		std::string key;
	};

	struct Friend : public Client {
		Friend();
		std::string addr;
		ushort port;
	};

	Config(int argc, char* argv[]);

	static void printUsage(std::ostream& stream);

	std::string configPath;
	std::string logFormat;
	std::string logLevel;

	std::string nodeName;
	uint16_t parallel;

	std::string cacheDir;
	int cacheSizeMB;

	uint16_t tcpPort;
	std::string unixSocket;
	std::string unixPerms;
	uint16_t inspectPort;

	std::vector<Source> sources;
	std::vector<Friend> friends;
	std::vector<Client> clients;
};

}
#endif // CONFIG_HPP
