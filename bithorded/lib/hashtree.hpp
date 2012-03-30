/*
    Copyright 2012 <copyright holder> <email>

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
	typedef typename HashNode::HashAlgorithm HashAlgorithm;
	const static size_t DigestSize = HashNode::DigestSize;
	const static size_t BLOCKSIZE = 1024;

	HashTree(BackingStore& store) :
		_store(store),
		_hasher(),
		_leaves(calc_leaves(store.size()))
	{}

	Node& getRoot() {
		return _store[TREE_ROOT_NODE];
	}

	void setData(uint offset, const byte* input, size_t length) {
		BOOST_ASSERT((length == BLOCKSIZE) || (offset == (_leaves-1)));
		NodeIdx currentIdx = _store.leaf(offset);
		Node& current = _store[currentIdx];
		computeLeaf(input, length, current.digest);
		current.state = Node::State::SET;

		Node currentCpy = current;

		while (not currentIdx.isRoot()) {
			NodeIdx siblingIdx = currentIdx.sibling();
			Node siblingCpy = _store[siblingIdx];

			NodeIdx parentIdx = currentIdx.parent();
			Node& parent = _store[parentIdx];
			if (parent.state == Node::State::SET) // TODO: Should probably verify it?
				break;

			if (siblingIdx.isValid()) {
				if (siblingCpy.state != Node::State::SET) {
					break;
				} else {
					BOOST_ASSERT(!(currentIdx == siblingIdx));
					if (siblingIdx < currentIdx)
						computeInternal(siblingCpy, currentCpy, parent);
					else
						computeInternal(currentCpy, siblingCpy, parent);
				}
			} else {
				memcpy(parent.digest, currentCpy.digest, DigestSize);
			}
			parent.state = Node::State::SET;
			currentIdx = parentIdx;
			currentCpy = parent;
		}
	}

	bool isBlockSet(uint idx) {
		NodeIdx block = _store.leaf(idx);
		return _store[block].state == HashNode::State::SET;
	}

private:
	void computeLeaf(const byte* input, size_t length, byte* output) {
		_hasher.Update(&TREE_LEAF_PREFIX, 1);
		_hasher.Update(input, length);
		_hasher.Final(output);
	}

	void computeInternal(const Node& leftChild, const Node& rightChild, Node& output) {
		_hasher.Update(&TREE_INTERNAL_PREFIX, 1);
		_hasher.Update(leftChild.digest, DigestSize);
		_hasher.Update(rightChild.digest, DigestSize);
		_hasher.Final(output.digest);
	}

	TreeStore< Node, BackingStore > _store;
	HashAlgorithm _hasher;
	uint _leaves;
};

#endif // BITHORDED_HASHTREE_H
