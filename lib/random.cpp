/*
    Copyright 2012 <copyright holder> <email>

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

#include "random.h"

#include <stdlib.h>
#include <sys/time.h>
#include <unistd.h>

class RandomGen {
public:
	RandomGen() {
		timeval t;
		gettimeofday(&t, NULL);
		unsigned int seed = t.tv_sec;
		seed = seed*1000000 + t.tv_usec;
		seed = (seed << 8) + getpid(); // More than 64 new pids per microsecond is unlikely.
		srand(seed);
	}
	uint64_t rand64() {
		return (((uint64_t)rand()) << 32) | rand();
	}

	std::string randomAlphaNumeric(size_t len) {
		static const char alphanum[] =
			"0123456789"
			"ABCDEFGHIJKLMNOPQRSTUVWXYZ"
			"abcdefghijklmnopqrstuvwxyz";

		std::string s(len, ' ');
		for (size_t i = 0; i < len; ++i) {
			s[i] = alphanum[rand() % (sizeof(alphanum) - 1)];
		}

		return s;
	}
};

static RandomGen r;

uint64_t rand64()
{
	return r.rand64();
}

std::string randomAlphaNumeric(size_t len)
{
	return r.randomAlphaNumeric(len);
}

