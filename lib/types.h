#ifndef BITHORDE_TYPES_H
#define BITHORDE_TYPES_H

#include <sys/types.h>
#include <google/protobuf/repeated_field.h>

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

namespace bithorde {
typedef ::google::protobuf::RepeatedField<uint64_t> RouteTrace;
}

#endif // BITHORDE_TYPES_H
