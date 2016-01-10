#include "../lib/timer.h"

#include <boost/test/unit_test.hpp>

#include <boost/asio/io_service.hpp>
#include <boost/date_time/posix_time/posix_time_types.hpp>

namespace ptime = boost::posix_time;

ptime::ptime deadline(ptime::microsec_clock::universal_time()+ptime::hours(24));

boost::asio::io_service IO_SVC;
std::shared_ptr<TimerService> TSVC(new TimerService(IO_SVC));
std::size_t BIG_FAT_COUNTER(0);
std::vector<Timer> TIMERS;
ptime::millisec TIMEOUT(50);
ptime::ptime FAIL_TIMEOUT(ptime::microsec_clock::universal_time() + ptime::seconds(5));

void run(const ptime::ptime& a) {
	if (a >= FAIL_TIMEOUT) {
		BOOST_ASSERT_MSG(false, "Failed to run callbacks in allotted time");
		IO_SVC.stop();
	}
	if ((++BIG_FAT_COUNTER) >= TIMERS.size()) {
		IO_SVC.stop();
	}
}

BOOST_AUTO_TEST_CASE( timers_copyable )
{
	auto start = ptime::microsec_clock::universal_time();
	{
		std::vector<Timer> timers;
		for (int i=0; i < 1000; i++) {
			Timer t(*TSVC, &run);
			t.arm(TIMEOUT);
			timers.push_back(t);
		}
		for (int i=0; i < 1000; i++) {
			Timer t(*TSVC, &run);
			t.arm(start+TIMEOUT);
			timers.push_back(t);
		}
		TIMERS = timers;
	}

	BOOST_CHECK_EQUAL( TIMERS.size(), 2000 );
	IO_SVC.run();
	auto stop = ptime::microsec_clock::universal_time();
	BOOST_CHECK_GE( (stop - start).total_microseconds(), TIMEOUT.total_microseconds() );
}
