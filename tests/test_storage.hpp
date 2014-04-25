#ifndef TEST_STORAGE_HPP
#define TEST_STORAGE_HPP

#include <vector>

template <typename _NodeType>
class TestStorage : public std::vector<_NodeType> {
public:
	typedef _NodeType Node;
	typedef Node* NodePtr;

	TestStorage(size_t count) : std::vector<Node>(count) {}

	Node* operator[](size_t offset) {
		return &std::vector<Node>::operator[](offset);
	}
};

#endif // TEST_STORAGE_HPP
