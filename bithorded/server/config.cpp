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
#include <boost/algorithm/string/predicate.hpp>
#include <boost/asio/ip/host_name.hpp>
#include <boost/assert.hpp>
#include <boost/foreach.hpp>
#include <boost/tokenizer.hpp>
#include <boost/program_options.hpp>
#include <iostream>
#include <fstream>

#include "buildconf.hpp"

using namespace std;

namespace asio = boost::asio;
namespace po = boost::program_options;

po::options_description cmdline_options;

class OptionGroup {
	std::string _name;
	std::map<string, po::variable_value> _map;
public:
	OptionGroup() {}
	OptionGroup(const std::string& name)
		: _name(name)
	{
	}

	const po::variable_value & operator[](const std::string &key) {
		return _map[key];
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

bithorded::Config::Config(int argc, char* argv[])
{
	po::options_description cli_options("Command-Line Options");
	cli_options.add_options()
		("version,v", "print version string")
		("help", "produce help message")
		("config,c", po::value<string>(&configPath)->default_value("/etc/bithorde.conf"),
			"Path to config-file")
	;

	po::options_description config_options("Config Options");
	config_options.add_options()
		("server.name", po::value<string>(&nodeName)->default_value(asio::ip::host_name()),
			"Name of this node, defaults to hostname")
		("server.tcpPort", po::value<uint16_t>(&tcpPort)->default_value(1337),
			"TCP port to listen on for incoming connections")
		("server.unixSocket", po::value<string>(&unixSocket)->default_value("/tmp/bithorde"),
			"Path to UNIX-socket to listen on")
	;

	cmdline_options.add(cli_options).add(config_options);

	DynamicMap vm;
	vm.store(po::parse_command_line(argc, argv, cmdline_options));
	notify(vm);

	if (vm.count("version"))
		throw VersionExit();

	if (!configPath.empty()) {
		std::ifstream cfg(configPath);
		vm.store(po::parse_config_file(cfg, config_options, true));
		notify(vm);
	}

	if (vm.count("help")) {
		throw ArgumentError("Usage:");
	}

	vector<OptionGroup> source_opts = vm.groups("source");
	for (auto opt=source_opts.begin(); opt != source_opts.end(); opt++) {
		Source src;
		src.name = opt->name();
		auto root_opt = (*opt)["root"];
		src.root = root_opt.as<string>();
		sources.push_back(src);
	}

	if (sources.empty()) {
		throw ArgumentError("Needs at least one source root to share.");
	}
}

void bithorded::Config::print_usage(ostream& stream)
{
	stream << cmdline_options << endl;
}
