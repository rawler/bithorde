
#include <boost/filesystem.hpp>
#include <boost/program_options.hpp>
#include <iostream>

#include <crypto++/files.h>
#include <log4cplus/configurator.h>
#include <log4cplus/hierarchy.h>

#include "buildconf.hpp"
#include "lib/hashes.h"
#include "server/config.hpp"
#include "server/server.hpp"

using namespace std;
namespace asio = boost::asio;
namespace fs = boost::filesystem;
namespace po = boost::program_options;

using namespace bithorded;

class Layout : public log4cplus::TTCCLayout {
public:
	Layout() : TTCCLayout() {
		dateFormat = "%Y-%m-%d %H:%M:%S.%q";
	}
};

int main(int argc, char* argv[]) {
	log4cplus::BasicConfigurator config;
	config.configure();
	auto root = log4cplus::Logger::getDefaultHierarchy().getRoot();
	auto layout = std::auto_ptr<log4cplus::Layout>(new Layout());
	auto appenders = root.getAllAppenders();
	for (auto iter = appenders.begin(); iter != appenders.end(); iter++)
		(*iter)->setLayout(layout);

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
		Config::printUsage(cerr);
		return -1;
	}
}
