#ifndef BITHORDE_ALLOCATOR_H
#define BITHORDE_ALLOCATOR_H

#include <queue>

template <typename T>
struct CachedAllocator {
private:
	std::queue<T> _freed;
	T _init;
	T _next;
public:
	CachedAllocator(T init) 
		: _init(init), _next(init)
	{}

	T allocate() {
		T res;
		if (_freed.empty()) {
			res = _next++;
		} else {
			res = _freed.front();
			_freed.pop();
		}
		return res;
	}

	void free(T x) {
		_freed.push(x);
	}

	void reset() {
		_next = _init;
		_freed = std::queue<T>();
	}
};

#endif // ALLOCATOR_H
