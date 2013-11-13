/*
    Copyright 2012 Ulrik Mikaelsson <email>

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


#include "asset.hpp"
#include "hashstore.hpp"

#include "../lib/grandcentraldispatch.hpp"
#include "../lib/rounding.hpp"

#include <boost/bind/protect.hpp>
#include <boost/enable_shared_from_this.hpp>
#include <boost/filesystem.hpp>
#include <boost/make_shared.hpp>
#include <boost/shared_array.hpp>

const size_t MAX_CHUNK = 64*1024;
const size_t PARALLEL_HASH_JOBS = 64;

using namespace std;
using namespace bithorded;
using namespace bithorded::store;

namespace fs = boost::filesystem;

StoredAsset::StoredAsset( GrandCentralDispatch& gcd, const string& id, const HashStore::Ptr hashStore, const IDataArray::Ptr& data ) :
	_gcd(gcd),
	_id(id),
	_data(data),
	_hashStore(hashStore),
	_hasher(*hashStore, 0)
{
	updateStatus();
}

void StoredAsset::async_read(uint64_t offset, size_t size, uint32_t timeout, bithorded::IAsset::ReadCallback cb)
{
	byte buf[MAX_CHUNK];
	auto read = _data->read(offset, size, buf);
	if (read > 0)
		cb(offset, std::string((char*)buf, read));
	else
		cb(offset, std::string());
}

size_t StoredAsset::can_read(uint64_t offset, size_t size)
{
	BOOST_ASSERT(size > 0);
	size_t res = 0;
	if (size > MAX_CHUNK)
		size = MAX_CHUNK;
	auto stopoffset = offset+size;
	auto lastbyteoffset = stopoffset-1;
	uint32_t firstBlock = offset / BLOCKSIZE;
	uint32_t lastBlock = lastbyteoffset / BLOCKSIZE;

	for (auto currentBlock = firstBlock; currentBlock <= lastBlock && _hasher.isBlockSet(currentBlock); currentBlock++) {
		res += BLOCKSIZE;
		if (currentBlock == firstBlock)
			res -= offset % BLOCKSIZE;
		if (currentBlock == lastBlock) {
			if (auto overflow = (stopoffset % BLOCKSIZE))
				res -= BLOCKSIZE - overflow;
		}
	}

	return res;
}

bool StoredAsset::hasRootHash()
{
	auto root = _hasher.getRoot();
	return (root->state == TigerNode::State::SET);
}

void StoredAsset::notifyValidRange(uint64_t offset, uint64_t size, std::function< void() > whenDone)
{
	uint64_t filesize = StoredAsset::size();
	uint64_t end = offset + size;
	offset = roundUp(offset, BLOCKSIZE);
	if (end != filesize)
		end = roundDown(end, BLOCKSIZE);

	updateHash(offset, end, whenDone);
}

const string& StoredAsset::id() const {
	return _id;
}

uint64_t StoredAsset::size() {
	return _data->size();
}

void StoredAsset::updateStatus()
{
	auto trx = status.change();
	// TODO: trx->set_availability(_hasher.getCoveragePercent()*10);
	trx->set_size(_data->size());
	auto root = _hasher.getRoot();
	if (root->state == TigerNode::State::SET) {
		trx->set_status(bithorde::SUCCESS);
		trx->clear_ids();
		auto tigerId = trx->mutable_ids()->Add();
		tigerId->set_type(bithorde::TREE_TIGER);
		tigerId->set_id(root->digest, TigerNode::DigestSize);
	}
}

boost::shared_array<byte> crunch_piece(IDataArray* file, uint64_t offset, size_t size) {
	byte BUF[StoredAsset::BLOCKSIZE];
	byte* res = new byte[Hasher::DigestSize];

	auto got = file->read(offset, size, BUF);
	if (got != static_cast<ssize_t>(size)) {
		throw ios_base::failure("Unexpected read error");
	}

	Hasher::Hasher::leafDigest(BUF, got, res);
	return boost::shared_array<byte>(res);
}

struct HashTail : public boost::enable_shared_from_this<HashTail> {
	uint64_t offset, end;

	GrandCentralDispatch& gcd;
	IDataArray::Ptr data;
	Hasher& hasher;
	boost::shared_ptr<StoredAsset> asset;
	std::function<void()> whenDone;

	HashTail(uint64_t offset, uint64_t end, GrandCentralDispatch& gcd, const IDataArray::Ptr& data, Hasher& hasher, boost::shared_ptr<StoredAsset> asset, std::function<void()> whenDone=0) :
		offset(offset),
		end(end),
		gcd(gcd),
		data(data),
		hasher(hasher),
		asset(asset),
		whenDone(whenDone)
	{}

	~HashTail() {
		asset->updateStatus();
		if (whenDone)
			whenDone();
	}
	
	bool empty() const { return offset >= end; }

	void chewNext() {
		if (empty())
			return;
		size_t blockSize = StoredAsset::BLOCKSIZE;
		if (offset+blockSize > end)
			blockSize = end - offset;
		
		auto job_handler = boost::bind(&crunch_piece, data.get(), offset, blockSize);
		auto result_handler = boost::bind(&HashTail::add_piece, shared_from_this(), (uint32_t)(offset/StoredAsset::BLOCKSIZE), _1);

		offset += blockSize;

		gcd.submit(job_handler, result_handler);
	}

	void add_piece(uint32_t offset, boost::shared_array<byte> leafDigest) {
		hasher.setLeaf(offset, leafDigest.get());

		if (!empty())
			chewNext();
	}
};

void StoredAsset::updateHash(uint64_t offset, uint64_t end, std::function< void() > whenDone)
{
	boost::shared_ptr<HashTail> tail(boost::make_shared<HashTail>(offset, end, _gcd, _data, _hasher, shared_from_this(), whenDone));
	
	for (size_t i=0; (i < PARALLEL_HASH_JOBS) && !tail->empty(); i++ ) {
		tail->chewNext();
	}
}

#pragma pack(push, 1)
struct V1Header {
	uint8_t format;
	uint32_t _leafBlocks;

	uint32_t leafBlocks() {
		return ntohl(_leafBlocks);
	}

	uint32_t leafBlocks(uint32_t val) {
		_leafBlocks = htonl(val);
		return val;
	}
};
#pragma pack(pop)

bool openAssetV1 (const boost::filesystem::path& path, RandomAccessFile::Mode mode, HashStore::Ptr& hashStore, IDataArray::Ptr& dataStore) {
	auto metaFile = boost::make_shared<RandomAccessFile>(path/"meta", RandomAccessFile::READWRITE);

	V1Header hdr;
	auto read = metaFile->read(0, sizeof(V1Header), (byte*)&hdr);
	if (read != sizeof(V1Header))
		throw ios_base::failure("Failed to read header from "+path.string());
	if (hdr.format != 0x01)
		throw ios_base::failure("Unknown format of file "+path.string());
	hashStore = boost::make_shared<HashStore>(boost::make_shared<DataArraySlice>(metaFile, sizeof(hdr)));
	dataStore = boost::make_shared<RandomAccessFile>(path/"data", mode);

	return true;
}

bool bithorded::store::openAsset( const boost::filesystem::path& path, HashStore::Ptr& hashStore, IDataArray::Ptr& dataStore ) {
	switch (fs::status(path/"data").type()) {
	case boost::filesystem::file_not_found:
		return false;
	case boost::filesystem::symlink_file:
		return openAssetV1(path, RandomAccessFile::READ, hashStore, dataStore);
	case boost::filesystem::regular_file:
		return openAssetV1(path, RandomAccessFile::READWRITE, hashStore, dataStore);
	default:
		return false;
	}
}

HashStore::Ptr bithorded::store::createMetaFile(const boost::filesystem::path& assetPath, uint64_t assetSize) {
	uint64_t leafBlocks = HashStore::leaves_needed(assetSize);
	uint64_t allBlocks = treesize(leafBlocks);
	auto file = boost::make_shared<RandomAccessFile>(assetPath/"meta", RandomAccessFile::READWRITE, sizeof(V1Header)+(allBlocks*sizeof(HashStore::Node)));

	V1Header hdr;
	hdr.format = 0x01;
	hdr.leafBlocks(leafBlocks);
	if (file->write(0, &hdr, sizeof(hdr)) != sizeof(hdr))
		throw ios_base::failure("Failed to write header to "+assetPath.string());

	auto hashSlice = boost::make_shared<DataArraySlice>(file, sizeof(hdr));
	return boost::make_shared<HashStore>(hashSlice);
}


