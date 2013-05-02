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

#include "config.hpp"

#include <boost/any.hpp>
#include <boost/algorithm/string.hpp>
#include <boost/asio/ip/host_name.hpp>
#include <boost/assert.hpp>
#include <boost/filesystem.hpp>
#include <boost/foreach.hpp>
#include <boost/tokenizer.hpp>
#include <boost/program_options.hpp>
#include <iostream>
#include <fstream>

#include <crypto++/base64.h>

#include "buildconf.hpp"

using namespace std;

namespace asio = boost::asio;
namespace po = boost::program_options;

po::options_description cli_options("Command-Line Options");

class OptionGroup {
	std::string _name;
	std::map<string, po::variable_value> _map;
public:
	OptionGroup() {}
	OptionGroup(const std::string& name)
		: _name(name)
	{
	}

	po::variable_value dummy_value;
	const po::variable_value & operator[](const std::string &key) const {
		auto iter = _map.find(key);
		if (iter != _map.end())
			return iter->second;
		else
			return dummy_value;
	}

	string name() const {
		auto periodpos = _name.rfind('.');
		if (periodpos == string::npos)
			return _name;
		else
			return _name.substr(periodpos+1);
	}

	void insert(const string& key, const po::variable_value& value) {
		_map[key] = value;
	}
};

class DynamicMap : public po::variables_map {
	map< string, OptionGroup> _groups;
public:
	void store(const po::basic_parsed_options<char>& opts) {
		for (auto opt=opts.options.begin(); opt != opts.options.end(); opt++ ) {
			size_t periodpos = opt->string_key.rfind('.');
			if (periodpos != string::npos) {
				string group_name = opt->string_key.substr(0, periodpos);
				if (!_groups.count(group_name))
					_groups[group_name] = OptionGroup(group_name);

				// TODO: now just pushes the first value, should support multi-value
				if (opt->value.size()) {
					string key_name = opt->string_key.substr(periodpos+1);
					po::variable_value v(opt->value.front(), false);
					_groups[group_name].insert(key_name, v);
				}
			}
		}
		po::store(opts, *this, true);
	}

	vector<OptionGroup> groups(const string& prefix) {
		vector<OptionGroup> res;
		for (auto group=_groups.begin(); group != _groups.end(); group++ ) {
			if (boost::starts_with(group->first, prefix))
				res.push_back(group->second);
		}
		return res;
	}
};

bithorded::Config::Client::Client() :
	name(), cipher(CLEARTEXT), key()
{}

bithorded::Config::Friend::Friend() :
	addr(), port(0)
{}


void read_client(const OptionGroup& options, bithorded::Config::Client& c) {
	c.name = options.name();
	auto key = options["key"];
	if (!key.empty())
		CryptoPP::StringSource(key.as<string>(), true,
			new CryptoPP::Base64Decoder(
				new CryptoPP::StringSink(c.key)));
	auto cipher_ = options["cipher"];
	if (!cipher_.empty()) {
		auto cipher = cipher_.as<string>();
		boost::to_upper(cipher);
		if ((cipher == "RC4") || (cipher == "ARC4"))
			c.cipher = bithorded::Config::Client::RC4;
		else if (cipher == "AES")
			c.cipher = bithorded::Config::Client::AES_CTR;
		else if ((cipher == "PLAIN") || cipher == "CLEARTEXT")
			c.cipher = bithorded::Config::Client::CLEARTEXT;
	}
}

bithorded::Config::Config(int argc, char* argv[])
{
	cli_options.add_options()
		("version,v", "print version string")
		("help", "produce help message")
		("config,c", po::value<string>(&configPath)->default_value("/etc/bithorde.conf"),
			"Path to config-file")
	;

	po::options_description server_options("Server Options");
	server_options.add_options()
		("server.name", po::value<string>(&nodeName)->default_value(asio::ip::host_name()),
			"Name of this node, defaults to hostname")
		("server.tcpPort", po::value<uint16_t>(&tcpPort)->default_value(1337),
			"TCP port to listen on for incoming connections")
		("server.inspectPort", po::value<uint16_t>(&inspectPort)->default_value(5000),
			"HTTP port to serve up inspection interface on")
		("server.unixSocket", po::value<string>(&unixSocket)->default_value("/tmp/bithorde"),
			"Path to UNIX-socket to listen on")
		("server.unixPerms", po::value<string>(&unixPerms)->default_value("0666"),
			"Permissions for the created UNIX-socket.")
	;

	po::options_description cache_options("Cache Options");
	cache_options.add_options()
		("cache.dir", po::value<string>(&cacheDir)->default_value("/var/cache/bithorde"),
			"Directory for the cache. Set to empty to disable.")
		("cache.size", po::value<int>(&cacheSizeMB)->default_value(1024),
			"Max size of the cache, in MB.")
	;

	cli_options.add(server_options).add(cache_options);

	DynamicMap vm;
	vm.store(po::parse_command_line(argc, argv, cli_options));
	notify(vm);

	if (vm.count("version"))
		throw VersionExit();

	if (!configPath.empty()) {
		po::options_description config_options;
		config_options.add(server_options).add(cache_options);
		std::ifstream cfg(configPath);
		if (!cfg.is_open())
			throw ArgumentError("Failed to open config-file");
		vm.store(po::parse_config_file(cfg, config_options, true));
		if (cfg.bad()) {
			ostringstream buf;
			buf << "Failed to read config-file: " << configPath;
			throw ArgumentError(buf.str());
		}
		notify(vm);
	}

	if (vm.count("help")) {
		throw ArgumentError("Usage:");
	}

	vector<OptionGroup> source_opts = vm.groups("source");
	for (auto opt=source_opts.begin(); opt != source_opts.end(); opt++) {
		Source src;
		src.name = opt->name();
		src.root = (*opt)["root"].as<string>();
		sources.push_back(src);
	}

	vector<OptionGroup> friend_opts = vm.groups("friend");
	for (auto opt=friend_opts.begin(); opt != friend_opts.end(); opt++) {
		Friend f;
		read_client(*opt, f);
		auto opt_addr = (*opt)["addr"];
		if (!opt_addr.empty()) {
			string addr = opt_addr.as<string>();
			size_t colpos = addr.rfind(':');
			f.addr = addr.substr(0, colpos);
			if (colpos == string::npos)
				f.port = 1337;
			else
				f.port = boost::lexical_cast<ushort>(addr.substr(colpos+1));
		}
		friends.push_back(f);
	}

	vector<OptionGroup> client_opts = vm.groups("client");
	for (auto opt=client_opts.begin(); opt != client_opts.end(); opt++) {
		Client c;
		read_client(*opt, c);
		clients.push_back(c);
	}

	if (friends.empty() && sources.empty() && cacheDir.empty()) {
		throw ArgumentError("Needs at least one friend or source root to receive assets.");
	}
}

void bithorded::Config::print_usage(ostream& stream)
{
	stream << cli_options << endl;
}
