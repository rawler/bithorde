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


#ifndef BITHORDED_RANDOMACCESSFILE_H
#define BITHORDED_RANDOMACCESSFILE_H

#include <boost/core/noncopyable.hpp>
#include <boost/filesystem/path.hpp>

#include "lib/types.h"

namespace bithorded {

class IDataArray {
public:
	typedef std::shared_ptr<IDataArray> Ptr;

	virtual uint64_t size() const = 0;

	/**
	 * Reads up to /size/ bytes from file and returns amount read.
	 *
	 * @arg offset - to read from
	 * @arg buf - a buffer allocated with at least /size/ capacity
	 * @arg size - size of buf
	 * @returns pointer to data, may or may not be pointer to /buf/
	 */
	virtual ssize_t read(uint64_t offset, size_t size, byte* buf) const = 0;

	/**
	 * Writes /size/ bytes to file beginning at /offset/.
	 */
	virtual ssize_t write(uint64_t offset, const void* src, size_t size) = 0;

	/**
	 * Writes a given string-buf to file beginning at /offset/.
	 */
	virtual ssize_t write(uint64_t offset, const std::string& buf);

	/**
	 * Describe the DataArray I.E. the name of the file
	 */
	virtual std::string describe() = 0;
};

std::string dataArrayToString(const IDataArray& dataarray);

class RandomAccessFile : public IDataArray {
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
	RandomAccessFile( const boost::filesystem::path& path, RandomAccessFile::Mode mode = READ, uint64_t size = 0 );
	RandomAccessFile( const RandomAccessFile& ) = delete;
	~RandomAccessFile();

	/**
	 * Open the given file. May throw std::ios_base::failure.
	 *
	 * non-zero size means open and create file of this size
	 */
	void open(const boost::filesystem::path& path, RandomAccessFile::Mode mode = READ, uint64_t size = 0);

	/**
	 * Close the underlying file
	 */
	void close();

	/**
	 * See if file is currently open
	 */
	bool isOpen() const;

	/**
	 * The number of bytes in the open file
	 */
	virtual uint64_t size() const;

	/**
	 * The number of blocks of /blockSize/ required to hold all file content
	 */
	uint32_t blocks(size_t blockSize) const;

	/// Implement IDataArray
	virtual ssize_t read(uint64_t offset, size_t size, byte* buf) const;
	virtual ssize_t write(uint64_t offset, const void* src, size_t size);
	virtual std::string describe();

	/**
	 * Return the path used to open the file
	 */
	const boost::filesystem::path& path() const;
};

class DataArraySlice : boost::noncopyable, public IDataArray {
	IDataArray::Ptr _parent;
	uint64_t _offset, _size;
public:
	DataArraySlice(const IDataArray::Ptr& parent, uint64_t offset, uint64_t size);
	DataArraySlice(const IDataArray::Ptr& parent, uint64_t offset);
	virtual uint64_t size() const;
	virtual ssize_t read ( uint64_t offset, size_t size, byte* buf ) const;
	virtual ssize_t write ( uint64_t offset, const void* src, size_t size );
    virtual std::string describe();
};

}

#endif // BITHORDED_RANDOMACCESSFILE_H
