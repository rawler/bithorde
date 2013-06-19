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


#ifndef BITHORDED_RANDOMACCESSFILE_H
#define BITHORDED_RANDOMACCESSFILE_H

#include <boost/filesystem/path.hpp>
#include <boost/noncopyable.hpp>

#include "lib/types.h"

class RandomAccessFile : boost::noncopyable {
	int _fd;
	boost::filesystem::path _path;
	uint64_t _size;
public:
	enum Mode {
	READ = 1,
	WRITE = 2,
	READWRITE = READ|WRITE,
	};

	RandomAccessFile();
	RandomAccessFile(const boost::filesystem::path& path, RandomAccessFile::Mode mode = READ, uint64_t size = 0);
	~RandomAccessFile();

	/**
	 * Open the given file. May throw std::ios_base::failure.
	 */
	void open(const boost::filesystem::path& path, RandomAccessFile::Mode mode = READ, uint64_t size = 0);

	/**
	 * Close the underlying file
	 */
	void close();

	/**
	 * See if file is currently open
	 */
	bool is_open() const;

	/**
	 * The number of bytes in the open file
	 */
	uint64_t size() const;

	/**
	 * The number of blocks of /blockSize/ required to hold all file content
	 */
	uint32_t blocks(size_t blockSize) const;

	/**
	 * Reads up to /size/ bytes from file and returns a pointer to the data.
	 *
	 * @arg buf - a buffer allocated with at least /size/ capacity
	 * @arg size - will be updated with actual read amount
	 * @returns pointer to data, may or may not be pointer to /buf/
	 */
	byte* read(uint64_t offset, size_t& size, byte* buf) const;

	/**
	 * Writes up to /size/ bytes to file beginning at /offset/.
	 */
	ssize_t write(uint64_t offset, const void* src, size_t size);

	/**
	 * Return the path used to open the file
	 */
	const boost::filesystem::path& path() const;
};

#endif // BITHORDED_RANDOMACCESSFILE_H
