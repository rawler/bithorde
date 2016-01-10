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

#include "buffer.hpp"

#include "client.h"

using namespace bithorde;

NullBuffer::NullBuffer() {
}

byte* NullBuffer::operator*() const {
	return NULL;
}

size_t NullBuffer::size() const {
	return 0;
}

const NullBuffer::Ptr NullBuffer::instance(std::make_shared<NullBuffer>());

MemoryBuffer::MemoryBuffer ( size_t size )
	: _buf(new byte[size]), _size(size)
{
}

byte* MemoryBuffer::operator*() const {
	return _buf.get();
}

void MemoryBuffer::trim ( size_t new_size ) {
	BOOST_ASSERT(new_size <= _size);
	_size = new_size;
}

size_t MemoryBuffer::size() const {
	return _size;
}

ReadResponseCtxBuffer::ReadResponseCtxBuffer ( const std::shared_ptr< MessageContext< Read_Response > > msgCtx )
	: _msgCtx(msgCtx)
{
}

byte* ReadResponseCtxBuffer::operator*() const {
	return (byte*)_msgCtx->message().content().data();
}

size_t ReadResponseCtxBuffer::size() const {
	return _msgCtx->message().content().size();
}

DataSegmentCtxBuffer::DataSegmentCtxBuffer ( const std::shared_ptr< MessageContext< DataSegment > > msgCtx )
	: _msgCtx(msgCtx)
{
}

byte* DataSegmentCtxBuffer::operator*() const {
	return (byte*)_msgCtx->message().content().data();
}

size_t DataSegmentCtxBuffer::size() const {
	return _msgCtx->message().content().size();
}



