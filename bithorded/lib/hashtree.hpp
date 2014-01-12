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
// TODO: FUGLY. Should not be dependent on serialized form.
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
		CryptoPP::StringSource pipe(digest, DigestSize, false,
			new RFC4648Base32Encoder(
				new CryptoPP::StringSink(res)));
		pipe.PumpAll();
		return res;
	}
};
#pragma pack(pop)

template <typename HashAlgorithm>
bool operator==(const HashNode< HashAlgorithm >& a, const HashNode< HashAlgorithm >& b)
{
	if (a.state != b.state)
		return !memcmp(a.digest, b.digest, HashNode<HashAlgorithm>::DigestSize);
	else
		return true;
}

template <typename HashAlgorithm>
bool operator!=(const HashNode< HashAlgorithm >& a, const HashNode< HashAlgorithm >& b)
{
	return !(a == b);
}


template <typename HashAlgorithm>
struct TreeHasher {
	const static size_t DigestSize = HashAlgorithm::DIGESTSIZE;

	const static size_t UNITSIZE = 1024;
	const static byte TREE_INTERNAL_PREFIX = 0x01;
	const static byte TREE_LEAF_PREFIX = 0x00;

	static void leafDigest(const byte* input, size_t length, byte* output) {
		BOOST_ASSERT(length <= UNITSIZE);
		HashAlgorithm hasher;
		hasher.Update(&TREE_LEAF_PREFIX, 1);
		hasher.Update(input, length);
		hasher.Final(output);
	}

	static size_t calcSplit(size_t length) {
		size_t leaves = (length + UNITSIZE-1) / UNITSIZE;
		size_t res(UNITSIZE);
		leaves -= 1;
		while (leaves > 1) {
			leaves >>= 1;
			res <<= 1;
		}
		return res;
	}

	static void rootDigest(const byte* input, size_t length, byte* output) {
		if (length <= UNITSIZE) {
			leafDigest(input, length, output);
		} else {
			size_t split(calcSplit(length));
			byte buf[DigestSize];
			HashAlgorithm hasher;
			hasher.Update(&TREE_INTERNAL_PREFIX, 1);

			// Left subtree
			rootDigest(input, split, buf);
			hasher.Update(buf, sizeof(buf));

			// Right subtree
			rootDigest(input+split, length-split, buf);
			hasher.Update(buf, sizeof(buf));

			hasher.Final(output);
		}
	}
};

template<typename HashAlgorithm> const size_t TreeHasher<HashAlgorithm>::UNITSIZE;
template<typename HashAlgorithm> const byte TreeHasher<HashAlgorithm>::TREE_INTERNAL_PREFIX;
template<typename HashAlgorithm> const byte TreeHasher<HashAlgorithm>::TREE_LEAF_PREFIX;

template <typename BackingStore>
class HashTree
{
public:
	typedef typename BackingStore::Node Node;
	typedef typename BackingStore::NodePtr NodePtr;
	typedef typename Node::HashAlgorithm HashAlgorithm;
	typedef TreeHasher<HashAlgorithm> Hasher;
	const static size_t DigestSize = Node::DigestSize;

	HashTree(BackingStore& store, uint8_t skipLevels) :
		_store(store),
		_hasher(),
		_leaves(calc_leaves(store.size())),
		_leafSize(Hasher::UNITSIZE << skipLevels)
	{
	}

	NodePtr getRoot() {
		return _store[TREE_ROOT_NODE];
	}

	const NodePtr getRoot() const {
		return _store[TREE_ROOT_NODE];
	}

	uint8_t getCoveragePercent() const {
		uint16_t res(0);
		uint32_t layerSize = 128;
		if (layerSize > _leaves)
			layerSize = _leaves;
		for (uint32_t i=0; i < layerSize; i++) {
			if (_store[NodeIdx(i, layerSize)]->state == Node::State::SET) {
				res += 100;
			}
		}
		return res / layerSize;
	}

	void setData(uint64_t offset, const byte* input, size_t length) {
		BOOST_ASSERT(!(offset % _leafSize));
		BOOST_ASSERT(!(length % _leafSize) || ((offset+length)/_leafSize == (_leaves-1)));
		byte digest[DigestSize];
		while (length) {
			size_t blockLength = std::min(length, _leafSize);
			Hasher::rootDigest(input, blockLength, digest);
			setLeaf(offset/_leafSize, digest);

			offset += blockLength;
			input += blockLength;
			length -= blockLength;
		}
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
			return _store[block]->state == Node::State::SET;
	}

private:
	void _computeInternal(const Node& leftChild, const Node& rightChild, Node& output) {
		_hasher.Update(&Hasher::TREE_INTERNAL_PREFIX, 1);
		_hasher.Update(leftChild.digest, DigestSize);
		_hasher.Update(rightChild.digest, DigestSize);
		_hasher.Final(output.digest);
	}

	TreeStore< Node, BackingStore > _store;
	HashAlgorithm _hasher;
	size_t _leaves;
	size_t _leafSize;
};

#endif // BITHORDED_HASHTREE_H
