/*
    Copyright 2013 "Paul" <http://stackoverflow.com/users/858219/paul>

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


#ifndef RELATIVEPATH_HPP
#define RELATIVEPATH_HPP

#include <boost/filesystem/path.hpp>
#include <boost/filesystem/operations.hpp>

namespace boost { namespace filesystem {
	boost::filesystem::path relative(const boost::filesystem::path& path, const boost::filesystem::path& relative_to = boost::filesystem::current_path());
	void create_relative_symlink( const boost::filesystem::path& to, const boost::filesystem::path& new_symlink );
	bool path_is_in(const boost::filesystem::path& path, const boost::filesystem::path& folder);
}}

#endif // RELATIVEPATH_HPP
