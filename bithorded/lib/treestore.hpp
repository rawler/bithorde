/*
    Copyright 2016 Ulrik Mikaelsson <ulrik.mikaelsson@gmail.com>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
*/


/// TreeStore as described briefly in http://www.lucidchart.com/publicSegments/view/4f5910e5-22dc-4b22-ba2c-6fee0a7c6148

#ifndef BITHORDED_TREESTORE_H
#define BITHORDED_TREESTORE_H

#include <math.h>
#include <stdint.h>
#include <ostream>

#include <boost/assert.hpp>

inline uint32_t parentlayersize(uint32_t nodes) {
	if (nodes > 1)
		return (nodes+1)/2;
	else
		return 0;
}

// Calculates the required number of nodes in a tree, with a leaf-layer of n leaves
inline uint32_t treesize(uint32_t leafs) {
	if (leafs > 1)
		return leafs + treesize(parentlayersize(leafs));
	else
		return leafs;
}

uint32_t calc_leaves(uint32_t treesize);

struct NodeIdx {
	uint32_t nodeIdx;
	uint32_t layerSize;

	NodeIdx(uint32_t nodeIdx, uint32_t layerSize)
		: nodeIdx(nodeIdx), layerSize(layerSize)
	{}

	NodeIdx parent() const {
		BOOST_ASSERT( not isRoot() );
		return NodeIdx(nodeIdx/2, parentlayersize(layerSize));
	}

	NodeIdx sibling() const {
		return NodeIdx(nodeIdx ^ 0x01, layerSize);
	}

	bool operator<(const NodeIdx& other) {
		BOOST_ASSERT(this->layerSize == other.layerSize);
		return this->nodeIdx < other.nodeIdx;
	}

	bool isValid() const {
		return nodeIdx < layerSize;
	}

	bool operator==(const NodeIdx& other) const {
		return (this->nodeIdx == other.nodeIdx)
			&& (this->layerSize == other.layerSize);
	}

	bool isRoot() const {
		return (layerSize == 1);
	}
};
const NodeIdx TREE_ROOT_NODE(0,1);

std::ostream& operator<<(std::ostream& str,const NodeIdx& idx);

template <typename Node, typename BackingStore>
class TreeStore
{
public:
	typedef typename BackingStore::NodePtr NodePtr;

	TreeStore(BackingStore& backingStore)
		: _storage(backingStore), _leaves(calc_leaves(backingStore.size()))
	{
		BOOST_ASSERT(backingStore.size() >= treesize(_leaves));
	}

	NodeIdx leaf(uint32_t i) const {
		return NodeIdx(i, _leaves);
	};

	NodePtr operator[](const NodeIdx& idx) {
		int layer_offset = treesize(parentlayersize(idx.layerSize));
		return _storage[layer_offset + idx.nodeIdx];
	}
	const NodePtr operator[](const NodeIdx& idx) const {
		int layer_offset = treesize(parentlayersize(idx.layerSize));
		return _storage[layer_offset + idx.nodeIdx];
	}

	uint32_t leaves() const {
		return _leaves;
	}

private:
	BackingStore& _storage;
	uint32_t _leaves;
};

#endif // BITHORDED_TREESTORE_H
