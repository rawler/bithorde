#include "../lib/timer.h"

#include <boost/test/unit_test.hpp>

#include <boost/asio/io_service.hpp>
#include <boost/shared_ptr.hpp>
#include <boost/date_time/posix_time/posix_time_types.hpp>

namespace ptime = boost::posix_time;

ptime::ptime deadline(ptime::microsec_clock::universal_time()+ptime::hours(24));

boost::asio::io_service IO_SVC;
boost::shared_ptr<TimerService> TSVC(new TimerService(IO_SVC));
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
	{
		std::vector<Timer> timers;
		for (int i=0; i < 1000; i++) {
			Timer t(*TSVC, &run);
			t.arm(TIMEOUT);
			timers.push_back(t);
		}
		auto now = ptime::microsec_clock::universal_time();
		for (int i=0; i < 1000; i++) {
			Timer t(*TSVC, &run);
			t.arm(now+TIMEOUT);
			timers.push_back(t);
		}
		TIMERS = timers;
	}

	IO_SVC.run();
}
