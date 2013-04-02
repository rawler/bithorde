#include <boost/test/unit_test.hpp>

#include "bithorded/lib/rounding.hpp"

using namespace std;

BOOST_AUTO_TEST_CASE( rounding_test )
{
	BOOST_CHECK_EQUAL( roundUp(0, 4), 0 );
	BOOST_CHECK_EQUAL( roundUp(2, 4), 4 );
	BOOST_CHECK_EQUAL( roundUp(3, 4), 4 );
	BOOST_CHECK_EQUAL( roundUp(4, 4), 4 );
	BOOST_CHECK_EQUAL( roundUp(5, 4), 8 );

	BOOST_CHECK_EQUAL( roundDown(0, 4), 0 );
	BOOST_CHECK_EQUAL( roundDown(2, 4), 0 );
	BOOST_CHECK_EQUAL( roundDown(3, 4), 0 );
	BOOST_CHECK_EQUAL( roundDown(4, 4), 4 );
	BOOST_CHECK_EQUAL( roundDown(5, 4), 4 );
}
