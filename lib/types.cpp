#include "types.h"

Buffer::Buffer()
{
	ptr = 0;
	size = capacity = 0;
}

Buffer::Buffer(byte* ptr, size_t len)
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

void Buffer::pop(size_t amount)
{
	if (amount == size) {
		size = 0;
		return;
	}
	memmove(ptr, ptr+amount, size-amount);
	size -= amount;
}