/*
    Copyright 2012 Ulrik Mikaelsson <ulrik.mikaelsson@gmail.com>

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


#include "randomaccessfile.hpp"

#include <boost/assert.hpp>
#include <boost/filesystem.hpp>
#include <fcntl.h>
#include <ios>
#include <sys/stat.h>
#include <sstream>

using namespace std;

namespace bsys = boost::system;
namespace fs = boost::filesystem;

RandomAccessFile::RandomAccessFile() :
	_fd(-1), _path(""), _size(0)
{}

RandomAccessFile::RandomAccessFile(const boost::filesystem::path& path, RandomAccessFile::Mode mode, uint64_t size) :
	_fd(-1), _path(""), _size(0)
{
	open(path, mode, size);
}

RandomAccessFile::~RandomAccessFile()
{
	close();
}

void RandomAccessFile::open(const boost::filesystem::path& path, RandomAccessFile::Mode mode, uint64_t size)
{
	int m;
	switch (mode) {
		case READ: m = O_RDONLY; break;
		case WRITE: m = O_WRONLY|O_CREAT; break;
		case READWRITE: m = O_RDWR|O_CREAT; break;
		default: throw std::ios_base::failure("Unknown open-mode");
	}
	_size = fs::exists(path) ? fs::file_size(path) : 0;

	if (_size != size) {
		if (size == 0) {
			size = _size;
		} else if (_size != 0) {
			ostringstream buf;
			buf << path << " exists with mismatching size, (" << size << " : " << fs::file_size(path) << ")";
			throw bsys::system_error(bsys::errc::make_error_code(bsys::errc::file_exists), buf.str());
		}
	}

	_fd = ::open(path.c_str(), m, S_IRUSR|S_IWUSR);
	if (_fd < 0) {
		throw bsys::system_error(bsys::errc::make_error_code(static_cast<bsys::errc::errc_t>(errno)), "Failed opening "+path.string());
	} else if ((_size == 0) && (ftruncate(_fd, size) == -1)) {
		::close(_fd);
		ostringstream buf;
		buf << "Failed truncating " << path.string() << " to " << size;
		throw bsys::system_error(bsys::errc::make_error_code(static_cast<bsys::errc::errc_t>(errno)), buf.str());
	}
	_path = path;
	_size = size;
}

void RandomAccessFile::close()
{
	if (is_open()) {
		::close(_fd);
		_fd = -1;
		_path == "";
	}
}

bool RandomAccessFile::is_open() const
{
	return _fd != -1;
}

uint64_t RandomAccessFile::size() const
{
	return _size;
}

uint32_t RandomAccessFile::blocks(size_t blockSize) const
{
	// Round up the number of blocks
	return (size() + blockSize - 1) / blockSize;
}

byte* RandomAccessFile::read(uint64_t offset, size_t& size, byte* buf) const
{
	ssize_t read = pread(_fd, buf, size, offset);
	if ( read > 0 ) {
		size = read;
		return buf;
	} else {
		size = 0;
		return NULL;
	}
}

ssize_t RandomAccessFile::write(uint64_t offset, const void* src, size_t size)
{
	ssize_t written = pwrite(_fd, src, size, offset);
	if ((size_t)written != size)
		throw std::ios_base::failure("Failed to write");
	return written;
}

const boost::filesystem::path& RandomAccessFile::path() const
{
	return _path;
}


