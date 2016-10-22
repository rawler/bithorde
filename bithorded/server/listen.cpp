/*
    Copyright 2016 Ulrik Mikaelsson <ulrik.mikaelsson@gmail.com>

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

#include "listen.hpp"

#include <cstdlib>
#include <boost/algorithm/string/split.hpp>

namespace bithorded {
using namespace std;

const int SD_LISTEN_FDS_START = 3;

int sd_get_named_socket(const std::string& name) {
    auto env = getenv("LISTEN_FDNAMES");
    if (!env) { return 0; }
    auto names = string(env);

    ushort idx=0;
    size_t start=0;
    while (true) {
        if (names.find(name, start) == start) {
            auto next = start + name.length();
            if (next == names.length() || names[next] == ':') {
                return SD_LISTEN_FDS_START + idx;
            }
        }
        start = names.find(':', start);
        if (start == string::npos) {
            return 0;
        }
        idx += 1;
        start += 1;
    }
}

}
