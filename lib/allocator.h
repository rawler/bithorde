#ifndef ALLOCATOR_H
#define ALLOCATOR_H

#include <queue>

template <typename T>
struct CachedAllocator {
private:
    std::queue<T> _freed;
    T _next;
public:
    CachedAllocator(T init) { _next = init; }

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
};

#endif // ALLOCATOR_H
