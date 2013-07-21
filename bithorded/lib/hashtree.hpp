/*
    Copyright 2012 Ulrik Mikaelsson <ulrik.mikaelsson@gmail.com>

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

#ifndef BITHORDED_HASHTREE_H
#define BITHORDED_HASHTREE_H

#include "lib/hashes.h"
#include "lib/types.h"

#include "treestore.hpp"

#pragma pack(push, 1)
template <typename _HashAlgorithm>
struct HashNode {
	typedef _HashAlgorithm HashAlgorithm;
	const static size_t DigestSize = HashAlgorithm::DIGESTSIZE;
	enum State {
		EMPTY = 0,
		SET = 1,
	};
	char state;
	byte digest[DigestSize];

	std::string base32Digest() {
		std::string res;
		CryptoPP::StringSource(digest, DigestSize, true,
			new RFC4648Base32Encoder(
				new CryptoPP::StringSink(res)));
		return res;
	}
};
#pragma pack(pop)

const static byte TREE_INTERNAL_PREFIX = 0x01;
const static byte TREE_LEAF_PREFIX = 0x00;

template <typename HashNode, typename BackingStore>
class HashTree
{
public:
	typedef HashNode Node;
	typedef typename BackingStore::NodePtr NodePtr;
	typedef typename HashNode::HashAlgorithm HashAlgorithm;
	const static size_t DigestSize = HashNode::DigestSize;
	const static size_t BLOCKSIZE = 1024;

	HashTree(BackingStore& store) :
		_store(store),
		_hasher(),
		_leaves(calc_leaves(store.size()))
	{}

	NodePtr getRoot() {
		return _store[TREE_ROOT_NODE];
	}

	const NodePtr getRoot() const {
		return _store[TREE_ROOT_NODE];
	}

	void setData(uint32_t offset, const byte* input, size_t length) {
		BOOST_ASSERT((length == BLOCKSIZE) || (offset == (_leaves-1)));
		byte digest[DigestSize];
		_computeLeaf(input, length, digest);
		setLeaf(offset, digest);
	}

	void propagate(const NodeIdx& currentIdx, const NodePtr& current) {
		if (currentIdx.isRoot())
			return;
		NodeIdx siblingIdx = currentIdx.sibling();

		NodeIdx parentIdx = currentIdx.parent();
		NodePtr parent = _store[parentIdx];
		if (parent->state == Node::State::SET) // TODO: Should probably verify it?
			return;

		if (siblingIdx.isValid()) {
			NodePtr sibling = _store[siblingIdx];
			if (sibling->state != Node::State::SET) {
				return;
			} else {
				BOOST_ASSERT(!(currentIdx == siblingIdx));
				if (siblingIdx < currentIdx)
					_computeInternal(*sibling, *current, *parent);
				else
					_computeInternal(*current, *sibling, *parent);
			}
		} else {
			memcpy(parent->digest, current->digest, DigestSize);
		}
		parent->state = Node::State::SET;
		propagate(parentIdx, parent);
	}

	void setLeaf(uint32_t offset, const byte* digest) {
		NodeIdx currentIdx = _store.leaf(offset);
		NodePtr current = _store[currentIdx];
		memcpy(current->digest, digest, DigestSize);
		current->state = Node::State::SET;

		propagate(currentIdx, current);
	}

	bool isBlockSet(uint32_t idx) {
		NodeIdx block = _store.leaf(idx);
		if (idx >= _leaves)
			return false;
		else
			return _store[block]->state == HashNode::State::SET;
	}

	static void computeLeaf(const byte* input, size_t length, byte* output) {
		HashAlgorithm hasher;
		hasher.Update(&TREE_LEAF_PREFIX, 1);
		hasher.Update(input, length);
		hasher.Final(output);
	}

private:
	void _computeLeaf(const byte* input, size_t length, byte* output) {
		_hasher.Update(&TREE_LEAF_PREFIX, 1);
		_hasher.Update(input, length);
		_hasher.Final(output);
	}

	void _computeInternal(const Node& leftChild, const Node& rightChild, Node& output) {
		_hasher.Update(&TREE_INTERNAL_PREFIX, 1);
		_hasher.Update(leftChild.digest, DigestSize);
		_hasher.Update(rightChild.digest, DigestSize);
		_hasher.Final(output.digest);
	}

	TreeStore< Node, BackingStore > _store;
	HashAlgorithm _hasher;
	uint32_t _leaves;
};

#endif // BITHORDED_HASHTREE_H
