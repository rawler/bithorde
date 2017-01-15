
#include <boost/filesystem.hpp>
#include <boost/log/utility/setup/common_attributes.hpp>
#include <boost/log/core.hpp>
#include <boost/log/sinks.hpp>
#include <iostream>

#include "buildconf.hpp"
#include "server/config.hpp"
#include "server/server.hpp"

using namespace std;
namespace asio = boost::asio;
namespace fs = boost::filesystem;
namespace sinks = boost::log::sinks;

using namespace bithorded;

struct noop_deleter
{
    void operator()(void const *) const {}
};

int main(int argc, char* argv[]) {
    boost::log::add_common_attributes();

    // Create a backend and attach std log to it
    auto backend = boost::make_shared< sinks::text_ostream_backend >();
    backend->add_stream(
        boost::shared_ptr< std::ostream >(&std::clog, noop_deleter()));

    // Enable auto-flushing after each log record written
    backend->auto_flush(true);

    // Wrap it into the frontend and register in the core.
    // The backend requires synchronization in the frontend.
    typedef sinks::synchronous_sink< sinks::text_ostream_backend > sink_t;
    boost::shared_ptr< sink_t > sink(new sink_t(backend));
    boost::log::core::get()->add_sink(sink);

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
