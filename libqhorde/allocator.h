#ifndef ALLOCATOR_H
#define ALLOCATOR_H

#include <QtCore/QVector>

template <typename T>
struct CachedAllocator {
private:
    QVector<T> _freed;
    T _next;
public:
    CachedAllocator(T init) { _next = init; }

    T allocate() {
        T res;
        int cached = _freed.size();
        if (cached) {
            res = _freed.last();
            _freed.resize(--cached);
        } else {
            res = _next++;
        }
        return res;
    }

    void free(T x) {
        _freed.append(x);
    }
};

#endif // ALLOCATOR_H
