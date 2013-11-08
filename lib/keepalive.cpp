/*
    Copyright 2013 <copyright holder> <email>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
*/

#include "keepalive.hpp"

#include "client.h"

const static boost::posix_time::seconds MINIMUM_PACKET_INTERVAL(90);
const static boost::posix_time::seconds MAX_PING_RESPONSE_TIME(15);

using namespace std;

bithorde::Keepalive::Keepalive(Client& client) :
	_client(client), _timer(*client.timerService(), boost::bind(&Keepalive::run, this)), _stale(false)
{
	reset();
}

void bithorde::Keepalive::reset()
{
	_stale = false;
	_timer.clear();
	_timer.arm(MINIMUM_PACKET_INTERVAL);
}

void bithorde::Keepalive::run()
{
	if (_stale) {
		cerr << "WARNING: " << _client.peerName() << " did not respond to ping. Disconnecting..." << endl;
		return _client.close();
	} else {
		Ping ping;
		ping.set_timeout(MAX_PING_RESPONSE_TIME.total_milliseconds());

		if (_client.sendMessage(Connection::Ping, ping, Message::NEVER, true)) {
			_stale = true;
			_timer.clear();
			_timer.arm(boost::posix_time::seconds(MAX_PING_RESPONSE_TIME.total_seconds() * 1.5));
		} else {
			cerr << "WARNING: " << _client.peerName() << " without input, failed to send prioritized ping. Disconnecting..." << endl;
			return _client.close();
		}
	}
}
