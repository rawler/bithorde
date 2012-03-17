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

#ifndef HASHTREE_H
#define HASHTREE_H

#include "lib/hashes.h"
#include "lib/types.h"

#include "treestore.hpp"

#pragma pack(push, 1)
template <int DigestSize>
struct HashNode {
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

template <typename HashAlgorithm, typename BackingStore>
class HashTree
{
public:
	typedef HashNode< HashAlgorithm::DIGESTSIZE > Node;
	const static size_t DIGESTSIZE = HashAlgorithm::DIGESTSIZE;
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
				memcpy(parent.digest, currentCpy.digest, DIGESTSIZE);
			}
			parent.state = Node::State::SET;
			currentIdx = parentIdx;
			currentCpy = parent;
		}
	}

private:
	void computeLeaf(const byte* input, size_t length, byte* output) {
		_hasher.Update(&TREE_LEAF_PREFIX, 1);
		_hasher.Update(input, length);
		_hasher.Final(output);
	}

	void computeInternal(const Node& leftChild, const Node& rightChild, Node& output) {
		_hasher.Update(&TREE_INTERNAL_PREFIX, 1);
		_hasher.Update(leftChild.digest, DIGESTSIZE);
		_hasher.Update(rightChild.digest, DIGESTSIZE);
		_hasher.Final(output.digest);
	}

	TreeStore< Node, BackingStore > _store;
	HashAlgorithm _hasher;
	uint _leaves;
};

#endif // HASHTREE_H
