#include <vector>

#include <boost/test/unit_test.hpp>

#include "lib/connection.h"

using namespace std;

BOOST_AUTO_TEST_CASE( message_queue )
{
	bithorde::MessageQueue mq;

	BOOST_ASSERT( mq.empty() );
	BOOST_CHECK_EQUAL( mq.size(), 0 );

	auto now = boost::chrono::steady_clock::now();
	for (auto i = 0; i < 32; i++ ) {
		boost::shared_ptr<bithorde::Message> msg(new bithorde::Message(now));
		msg->buf.insert(0, 1024, 'X');
		mq.enqueue(msg);
	}
	auto later = now + boost::chrono::seconds(15);
	for (auto i = 0; i < 32; i++ ) {
		boost::shared_ptr<bithorde::Message> msg(new bithorde::Message(later));
		msg->buf.insert(0, 1024, 'X');
		mq.enqueue(msg);
	}

	BOOST_ASSERT( !mq.empty() );
	BOOST_CHECK_EQUAL( mq.size(), 32*1024*2 );

	auto dequeued = mq.dequeue(8*1024, 1000); // 8kbyte/sec * 1 sec
	BOOST_ASSERT( !dequeued.empty() );
	BOOST_CHECK_EQUAL( dequeued.size(), 8 ); // Should get 8*1k messages
	BOOST_ASSERT( dequeued.front()->expires == later );

	auto minimal = mq.dequeue(0, 1); // 0 byte/sec * 1 msec
	BOOST_ASSERT( !minimal.empty() );
	BOOST_CHECK_EQUAL( minimal.size(), 1 ); // Should always get a minimum of 1 message, unless .empty()

	auto the_lot = mq.dequeue(1024*1024, 2000); // 1 MB/sec * 1 sec
	BOOST_ASSERT( !the_lot.empty() );
	BOOST_ASSERT( mq.empty() );
}
