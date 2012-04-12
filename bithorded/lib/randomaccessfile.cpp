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
#include <boost/filesystem/path.hpp>
#include <fcntl.h>
#include <ios>
#include <sys/stat.h>

RandomAccessFile::RandomAccessFile(const boost::filesystem::path& path, RandomAccessFile::Mode mode)
	: _path(path)
{
        int m;
        switch (mode) {
          case READ: m = O_RDONLY; break;
          case WRITE: m = O_WRONLY; break;
          case READWRITE: m = O_RDWR; break;
        }
	_fd = open(path.c_str(), m);
	if (_fd < 0)
		throw std::ios_base::failure("Failed opening "+path.string());
}

RandomAccessFile::~RandomAccessFile()
{
	if (_fd >= 0)
		close(_fd);
}

uint64_t RandomAccessFile::size() const
{
	struct stat s;
	fstat(_fd, &s);
	return s.st_size;
}

uint RandomAccessFile::blocks(size_t blockSize) const
{
	// Round up the number of blocks
	return (size() + blockSize - 1) / blockSize;
}

byte* RandomAccessFile::read(uint64_t offset, size_t& size, byte* buf)
{
	BOOST_ASSERT( size <= WINDOW_SIZE );
	ssize_t read = pread64(_fd, buf, size, offset);
	if ( read > 0 ) {
		size = read;
		return buf;
	} else {
		size = 0;
		return NULL;
	}
}

ssize_t RandomAccessFile::write(uint64_t offset, void* src, size_t size)
{
	BOOST_ASSERT( size <= WINDOW_SIZE );
	ssize_t written = pwrite64(_fd, src, size, offset);
	BOOST_ASSERT( (size_t)written == size ); // TODO: Real error-handling
	return written;
}

const boost::filesystem3::path& RandomAccessFile::path() const
{
	return _path;
}


