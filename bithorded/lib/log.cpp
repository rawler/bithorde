/*
    Copyright 2017 Ulrik Mikaelsson <ulrik.mikaelsson@gmail.com>

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

#include "log.hpp"

#include <boost/algorithm/string.hpp>
#include <boost/log/expressions/keyword.hpp>

using namespace bithorded;

#define NUM_SEVERITY_LEVELS 7
const char* severity_level_str[NUM_SEVERITY_LEVELS] = {
  "NULL",
  "TRACE",
  "DEBUG",
  "INFO",
  "WARNING",
  "ERROR",
  "FATAL"
};

const char * bithorded::log_severity_name(log_severity_level lvl) {
    if (lvl >= 0 && lvl < NUM_SEVERITY_LEVELS)
        return severity_level_str[lvl];
    else
        return 0;
}

log_severity_level bithorded::log_severity_by_name(const std::string& str) {
    auto upcase = boost::to_upper_copy<std::string>(str);
    for (auto i=0; i < NUM_SEVERITY_LEVELS; i++) {
        if (upcase == severity_level_str[i])
            return static_cast<log_severity_level>(i);
    }
    return log_severity_level::null;
}

std::ostream& bithorded::operator<< (std::ostream& strm, log_severity_level lvl)
{
    if (auto name = bithorded::log_severity_name(lvl))
        strm << name;
    else
        strm << static_cast< int >(lvl);
    return strm;
}

std::istream& bithorded::operator>> (std::istream& strm, log_severity_level &lvl)
{
    std::string name;
    strm >> name;

    if (auto x = bithorded::log_severity_by_name(name))
        lvl = x;
    else
        lvl = log_severity_level::debug;
    return strm;
}
