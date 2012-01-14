#ifndef TYPES_H
#define TYPES_H

#include <stdexcept>
#include <stdlib.h>
#include <string.h>
#include <vector>

#include <Poco/EventArgs.h>

typedef unsigned char byte;
typedef std::vector<byte> ByteArray;

struct Buffer {
	byte* ptr;
	size_t size, capacity;
	Buffer() {
		ptr = 0;
		size = capacity = 0;
	}
	Buffer(byte* ptr, size_t len) {
		this->ptr = ptr;
		this->capacity = len;
	}
	~Buffer() {
		if (ptr)
			free(ptr);
	}

	bool grow(size_t amount) {
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

	/**
	 * Allocate /amount/ bytes at the end of the buffer
	 */
	byte* allocate(size_t amount) {
		if ((size + amount) > capacity)
			if (!grow(amount*2))
				return 0;
		return ptr+size;
	}

	/**
	 * Notify /amount/ bytes at the end of the buffer has been filled.
	 */
	void charge(size_t amount) {
		size += amount;
	}

	/**
	 * Consume /amount/ bytes at the beginning of the buffer
	 */
	void pop(size_t amount) {
		if (amount == size) {
			size = 0;
			return;
		}
		memmove(ptr, ptr+amount, size-amount);
		size -= amount;
	}
};

extern Poco::EventArgs NO_ARGS;

#endif // TYPES_H