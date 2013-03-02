#ifndef TEST_STORAGE_HPP
#define TEST_STORAGE_HPP

#include <vector>

template <typename _NodeType>
class TestStorage : public std::vector<_NodeType> {
public:
	typedef _NodeType NodeType;
	typedef NodeType* NodePtr;

	TestStorage(size_t count) : std::vector<_NodeType>(count) {}

	NodeType* operator[](size_t offset) {
		return &std::vector<_NodeType>::operator[](offset);
	}
};

#endif // TEST_STORAGE_HPP
