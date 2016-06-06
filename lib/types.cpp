#include "types.h"

#include <stdexcept>
#include <stdlib.h>
#include <string.h>

Buffer::Buffer() :
	ptr(0), size(0), capacity(0), consumed(0)
{}

Buffer::Buffer(byte* ptr, size_t len) :
	size(0), consumed(0)
{
	this->ptr = ptr;
	this->capacity = len;
}

Buffer::~Buffer()
{
	if (ptr)
		free(ptr);
}

bool Buffer::grow(size_t amount)
{
	capacity += amount;
	byte* newptr = (byte*)realloc(ptr, capacity);
	if (newptr) {
		ptr = newptr;
	} else {
		size = capacity = 0;
		throw std::bad_alloc();
	}
	return capacity > 0;
}

byte* Buffer::allocate(size_t amount)
{
	if ((size + amount) > capacity)
		if (!grow(amount*2))
			return 0;
	return ptr+size;
}

void Buffer::charge(size_t amount)
{
	size += amount;
}

void Buffer::consume(size_t amount)
{
	consumed += amount;
}

void Buffer::pop()
{
	size -= consumed;
	if (size != 0) {
		memmove(ptr, ptr+consumed, size);
	}
	consumed = 0;
}

size_t Buffer::left()
{
	return size - consumed;
}
