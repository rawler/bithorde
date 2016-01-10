/*
 * Copyright 2014 <copyright holder> <email>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */

#ifndef BITHORDE_BUFFER_H
#define BITHORDE_BUFFER_H

#include <boost/shared_array.hpp>
#include <memory>

#include "types.h"

namespace bithorde {

class IBuffer {
public:
	typedef std::shared_ptr<IBuffer> Ptr;

	virtual byte * operator*() const = 0;
	virtual size_t size() const = 0;
};

class NullBuffer : public IBuffer {
public:
	NullBuffer();
	virtual byte * operator*() const;
	virtual size_t size() const;
	const static NullBuffer::Ptr instance;
};

class MemoryBuffer : public IBuffer {
	boost::shared_array<byte> _buf;
	size_t _size;
public:
	MemoryBuffer(size_t size);
	virtual byte* operator*() const;
	virtual void trim(size_t new_size);
	virtual size_t size() const;
};

template <typename T>
class MessageContext;
class Read_Response;

// Possible Optimization: create specialized class inheriting MessageContext<bithorde::Read_Response> and IBuffer,
// and instantiate directly from client
class ReadResponseCtxBuffer : public IBuffer {
	std::shared_ptr< MessageContext<bithorde::Read_Response> > _msgCtx;
public:
	ReadResponseCtxBuffer(const std::shared_ptr< MessageContext<Read_Response> > msgCtx);
	virtual byte* operator*() const;
	virtual size_t size() const;
};

class DataSegment;
class DataSegmentCtxBuffer : public IBuffer {
	std::shared_ptr< MessageContext<bithorde::DataSegment> > _msgCtx;
public:
	DataSegmentCtxBuffer(const std::shared_ptr< MessageContext<DataSegment> > msgCtx);
	virtual byte* operator*() const;
	virtual size_t size() const;
};

}

#endif // BUFFER_H
