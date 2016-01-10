#include <boost/test/unit_test.hpp>

#include "bithorded/lib/subscribable.hpp"

struct somestruct {
	int a;

	somestruct() : a(0) {}

	bool operator!=(const somestruct& other) const {
		return a != other.a;
	}
	bool operator==(const somestruct& other) const {
		return a == other.a;
	}
};

void react(somestruct * bound_res, const somestruct& old_value, const somestruct& new_value) {
	bound_res->a = new_value.a;
}

BOOST_AUTO_TEST_CASE( subscribable )
{
	Subscribable< somestruct > s;
	somestruct res;
	res.a = 4;

	s.onChange.connect(std::bind(&react, &res, std::placeholders::_1, std::placeholders::_2));

	{
		auto guard = s.change();
	}
	BOOST_CHECK(res.a == 4);

	{
		auto guard = s.change();
		guard->a = 15;
	}
	BOOST_CHECK(res.a == 15);
	BOOST_CHECK(res == *s);
	BOOST_CHECK(s == s);

	{
		somestruct next;
		next.a = 30;
		s = next;
	}
	BOOST_CHECK(res.a == 30);
	BOOST_CHECK(res == *s);
	BOOST_CHECK(s == res);
}
