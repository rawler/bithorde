#ifndef BITHORDE_TYPES_H
#define BITHORDE_TYPES_H

#include <stdexcept>
#include <stdlib.h>
#include <string.h>
#include <vector>

typedef unsigned char byte;

struct Buffer {
	byte* ptr;
	size_t size, capacity;
	Buffer();
	Buffer(byte* ptr, size_t len);
	~Buffer();

	bool grow(size_t amount);

	/**
	 * Allocate /amount/ bytes at the end of the buffer
	 */
	byte* allocate(size_t amount);

	/**
	 * Notify /amount/ bytes at the end of the buffer has been filled.
	 */
	void charge(size_t amount);

	/**
	 * Consume /amount/ bytes at the beginning of the buffer
	 */
	void pop(size_t amount);
};

#endif // BITHORDE_TYPES_H
