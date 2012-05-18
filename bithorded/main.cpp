
#include <boost/filesystem.hpp>
#include <boost/make_shared.hpp>
#include <boost/program_options.hpp>
#include <iostream>

#include <crypto++/files.h>
#include <log4cplus/configurator.h>

#include "buildconf.hpp"
#include "lib/hashes.h"
#include "store/linkedassetstore.hpp"
#include "server/config.hpp"
#include "server/server.hpp"

using namespace std;
namespace asio = boost::asio;
namespace fs = boost::filesystem;
namespace po = boost::program_options;

using namespace bithorded;

int main(int argc, char* argv[]) {
	log4cplus::BasicConfigurator config;
	config.configure();

	try {
		Config cfg(argc, argv);
		asio::io_service ioSvc;
		Server server(ioSvc, cfg);
		ioSvc.run();
		return 0;
	} catch (VersionExit& e) {
		return bithorde::exit_version();
	} catch (ArgumentError& e) {
		cerr << e.what() << endl;
		Config::print_usage(cerr);
		return -1;
	}
}
