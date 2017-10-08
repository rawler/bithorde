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


#include "relativepath.hpp"

#include <boost/filesystem.hpp>
#include <boost/algorithm/string.hpp>

namespace fs = boost::filesystem;

fs::path fs::_relative(const fs::path &path, const fs::path &relative_to )
{
	// create absolute paths
	fs::path p = fs::absolute(path);
	fs::path r = fs::absolute(relative_to);

	// if root paths are different, return absolute path
	if( p.root_path() != r.root_path() )
		return p;

	// initialize relative path
	fs::path result;

	// find out where the two paths diverge
	fs::path::const_iterator itr_path = p.begin();
	fs::path::const_iterator itr_relative_to = r.begin();
	while( *itr_path == *itr_relative_to && itr_path != p.end() && itr_relative_to != r.end() ) {
		++itr_path;
		++itr_relative_to;
	}

	// add "../" for each remaining token in relative_to
	while( itr_relative_to != r.end() ) {
		result /= "..";
		++itr_relative_to;
	}

	// add remaining path
	while( itr_path != p.end() ) {
		result /= *itr_path;
		++itr_path;
	}

	return result;
}

void fs::create_relative_symlink(const fs::path& to, const fs::path& new_symlink)
{
	fs::create_symlink(fs::_relative(to, new_symlink.parent_path()), new_symlink);
}

bool fs::path_is_in ( const fs::path& path, const fs::path& folder ) {
	return boost::starts_with(path, folder);
}

