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
#include <boost/asio/ip/host_name.hpp>
#include <boost/assert.hpp>
#include <boost/foreach.hpp>
#include <boost/tokenizer.hpp>
#include <boost/program_options.hpp>
#include <iostream>
#include <fstream>

using namespace std;

namespace asio = boost::asio;
namespace po = boost::program_options;

po::options_description cmdline_options;

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
		("storage.linkroot", po::value< vector<string> >(&linkroots),
			"Root folders allowed for linked upload (repeatable)")
	;

	cmdline_options.add(cli_options).add(config_options);

	po::variables_map vm;
	po::store(po::parse_command_line(argc, argv, cmdline_options), vm, true);
	notify(vm);

	if (!configPath.empty()) {
		std::ifstream cfg(configPath);
		po::store(po::parse_config_file(cfg, config_options), vm);
		notify(vm);
	}

	if (vm.count("version")) {
		// TODO: Git-version
		cerr << "Version: pre-alpha" << endl;
		exit(0);
	}

	if (vm.count("help")) {
		throw ArgumentError("Usage:");
	}

	if (linkroots.empty()) {
		throw ArgumentError("Needs at least one storage.linkroot to share.");
	}
}

void bithorded::Config::print_usage(ostream& stream)
{
	stream << cmdline_options << endl;
}
