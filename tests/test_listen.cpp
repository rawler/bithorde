#include <boost/test/unit_test.hpp>

#include "bithorded/server/listen.hpp"

using namespace std;
using bithorded::sd_get_named_socket;

BOOST_AUTO_TEST_CASE( listen_systemd )
{
	unsetenv("LISTEN_FDNAMES");

	BOOST_CHECK_EQUAL( sd_get_named_socket("nope"), 0 );

	setenv("LISTEN_FDNAMES", "tcp:unix", 1);

	BOOST_CHECK_EQUAL( sd_get_named_socket("tcp"), 3 );
	BOOST_CHECK_EQUAL( sd_get_named_socket("unix"), 4 );
	BOOST_CHECK_EQUAL( sd_get_named_socket("nope"), 0 );
}
