#ifndef BITHORDE_TYPES_H
#define BITHORDE_TYPES_H

#include <sys/types.h>
#include <google/protobuf/repeated_field.h>

typedef unsigned char byte;

// TODO: Refactor to try to hide pointers
struct Buffer {
	byte* ptr;
	size_t size, capacity, consumed;
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
	 * Mark bytes at the beginning of buffer as "consumed"
	 * Still valid and present until pop() though
	 */
	void consume(size_t amount);

	/**
	 * Expunge consumed bytes
	 */
	void pop();

	/**
	 * Number of bytes not consumed in buffer
	 */
    size_t left();
};

namespace bithorde {
typedef ::google::protobuf::RepeatedField<uint64_t> RouteTrace;
}

#endif // BITHORDE_TYPES_H
