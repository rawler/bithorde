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

#ifndef BITHORDED_LOG_H
#define BITHORDED_LOG_H

#include <boost/log/sources/logger.hpp>
#include <boost/log/sources/record_ostream.hpp>
#include <boost/log/sources/severity_logger.hpp>

namespace bithorded {
    namespace log = boost::log;

    // We define our own severity levels
    enum log_severity_level {
        null,
        trace,
        debug,
        info,
        warning,
        error,
        fatal,
    };

    typedef log::sources::severity_logger< log_severity_level > Logger;

    const char * log_severity_name(log_severity_level);
    log_severity_level log_severity_by_name(const std::string&);

    std::ostream& operator<< (std::ostream& strm, log_severity_level lvl);
    std::istream& operator>> (std::istream& strm, log_severity_level &lvl);
}

#endif //BITHORDED_LOG_H
