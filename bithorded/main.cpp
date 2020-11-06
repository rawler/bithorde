
#include <boost/filesystem.hpp>
#include <boost/log/core.hpp>
#include <boost/log/utility/setup.hpp>
#include <iostream>

#include "buildconf.hpp"
#include "lib/log.hpp"
#include "server/config.hpp"
#include "server/server.hpp"

using namespace std;
namespace asio = boost::asio;
namespace fs = boost::filesystem;
namespace keywords = boost::log::keywords;

using namespace bithorded;

struct noop_deleter
{
	void operator()(void const *) const {}
};

int main(int argc, char* argv[]) {
	boost::log::register_simple_filter_factory< bithorded::log_severity_level >("Severity");
	boost::log::register_simple_formatter_factory< bithorded::log_severity_level, char >("Severity");
	boost::log::add_common_attributes();

	try {
		Config cfg(argc, argv);
		boost::log::add_console_log(std::clog, keywords::format = cfg.logFormat, keywords::filter = "%Severity% >= " + cfg.logLevel);
		asio::io_context ioCtx;
		Server server(ioCtx, cfg);
		ioCtx.run();
		return 0;
	} catch (VersionExit& e) {
		return bithorde::exit_version();
	} catch (ArgumentError& e) {
		cerr << e.what() << endl;
		Config::printUsage(cerr);
		return -1;
	}
}
