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
#include <lib/buffer.hpp>

#include <boost/bind/protect.hpp>
#include <boost/enable_shared_from_this.hpp>
#include <boost/filesystem.hpp>
#include <boost/make_shared.hpp>
#include <boost/shared_array.hpp>
#include <stdexcept>

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
	_hasher(*hashStore, _hashStore->hashLevelsSkipped())
{
// TODO: Check data->size() against size of HashStore
	updateStatus();
}

void StoredAsset::async_read(uint64_t offset, size_t size, uint32_t timeout, bithorded::IAsset::ReadCallback cb)
{
	auto buf = boost::make_shared<bithorde::MemoryBuffer>(size);
	auto dataSize = _data->size();
	BOOST_ASSERT(offset < dataSize);
	auto clamped_size = std::min(size, static_cast<size_t>(dataSize-offset));
	auto read = _data->read(offset, clamped_size, **buf);
	if (read > 0) {
		buf->trim(read);
		cb(offset, buf);
	} else {
		cb(offset, bithorde::NullBuffer::instance);
	}
}

size_t StoredAsset::can_read(uint64_t offset, size_t size)
{
	BOOST_ASSERT(size > 0);
	size_t res = 0;
	if (size > MAX_CHUNK)
		size = MAX_CHUNK;
	auto stopoffset = offset+size;
	auto lastbyteoffset = stopoffset-1;
	auto blockSize = _hashStore->leafBlockSize();
	uint32_t firstBlock = offset / blockSize;
	uint32_t lastBlock = lastbyteoffset / blockSize;

	for (auto currentBlock = firstBlock; currentBlock <= lastBlock && _hasher.isBlockSet(currentBlock); currentBlock++) {
		res += blockSize;
		if (currentBlock == firstBlock)
			res -= offset % blockSize;
		if (currentBlock == lastBlock) {
			if (auto overflow = (stopoffset % blockSize))
				res -= blockSize - overflow;
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
	auto blockSize = _hashStore->leafBlockSize();

	offset = roundUp(offset, blockSize);
	if (end != filesize)
		end = roundDown(end, blockSize);

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
	byte BUF[size];
	byte* res = new byte[Hasher::DigestSize];

	auto got = file->read(offset, size, BUF);
	if (got != static_cast<ssize_t>(size)) {
		throw ios_base::failure("Unexpected read error");
	}

	Hasher::Hasher::rootDigest(BUF, got, res);
	return boost::shared_array<byte>(res);
}

struct HashTail : public boost::enable_shared_from_this<HashTail> {
	uint64_t offset, end;
	uint32_t blockSize;

	GrandCentralDispatch& gcd;
	IDataArray::Ptr data;
	Hasher& hasher;
	boost::shared_ptr<StoredAsset> asset;
	std::function<void()> whenDone;

	HashTail(uint64_t offset, uint64_t end, uint32_t blockSize, GrandCentralDispatch& gcd, const IDataArray::Ptr& data, Hasher& hasher, boost::shared_ptr<StoredAsset> asset, std::function<void()> whenDone=0) :
		offset(offset),
		end(end),
		blockSize(blockSize),
		gcd(gcd),
		data(data),
		hasher(hasher),
		asset(asset),
		whenDone(whenDone)
	{}

	// Function to run asynchronously from main-thread, to force update asset-status,
	// and possibly call callback when done.
	static void whenDoneWrapper(const boost::shared_ptr<StoredAsset>& asset, std::function<void()> whenDone) {
		asset->updateStatus();
		if (whenDone) {
			whenDone();
		}
	}

	~HashTail() {
		gcd.ioService().post(boost::bind(&HashTail::whenDoneWrapper, asset, whenDone));
	}
	
	bool empty() const { return offset >= end; }

	void chewNext() {
		if (empty())
			return;
		auto blockSize_ = std::min(static_cast<uint64_t>(blockSize), static_cast<uint64_t>(end - offset));
		
		auto job_handler = boost::bind(&crunch_piece, data.get(), offset, blockSize_);
		auto result_handler = boost::bind(&HashTail::add_piece, shared_from_this(), (uint32_t)(offset/blockSize), _1);

		offset += blockSize_;

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
	boost::shared_ptr<HashTail> tail(boost::make_shared<HashTail>(offset, end, _hashStore->leafBlockSize(), _gcd, _data, _hasher, shared_from_this(), whenDone));
	
	for (size_t i=0; (i < PARALLEL_HASH_JOBS) && !tail->empty(); i++ ) {
		tail->chewNext();
	}
}

template <typename T>
static inline T
hton_any(const T &input)
{
    T output(0);
    const std::size_t size = sizeof(T);
    uint8_t *data = reinterpret_cast<uint8_t *>(&output);

    for (std::size_t i = 1; i <= size; i++) {
        data[i-1] = input >> ((size - i) * 8);
    }

    return output;
}

#pragma pack(push, 1)
struct V1Header {
	uint8_t format;
	uint32_t _atoms;

	uint32_t atoms() {
		return ntohl( _atoms );
	}

	uint32_t atoms(uint32_t val) {
		_atoms = htonl(val);
		return val;
	}
};

struct V2Header {
	uint8_t format;
	uint64_t _atoms;
	uint8_t hashLevelsSkipped;

	uint64_t atoms() {
		return hton_any( _atoms );
	}

	uint64_t atoms(uint64_t val) {
		_atoms = hton_any(val);
		return val;
	}

	uint64_t storedLeaves() {
		auto x = atoms();
		auto res = x >> hashLevelsSkipped;
		if (x != (res << hashLevelsSkipped)) // Check for overflowing blocks
			res += 1;
		return res;
	}
};
#pragma pack(pop)

AssetMeta store::openV1AssetMeta ( const boost::filesystem::path& path ) {
	auto metaFile = boost::make_shared<RandomAccessFile>( path, RandomAccessFile::READWRITE);

	V1Header hdr;
        if (metaFile->size() < sizeof(hdr))
                throw ios_base::failure("File size less than constant header "+path.string());
	if (metaFile->read(0, sizeof(V1Header), (byte*)&hdr) != sizeof(V1Header))
		throw ios_base::failure("Failed to read V1 header from "+path.string());
	if (hdr.format != FileFormatVersion::V1FORMAT)
		throw ios_base::failure("Unknown format of file "+path.string());

	AssetMeta res;
	res.hashLevelsSkipped = 0;
	res.hashStore = boost::make_shared<HashStore>(boost::make_shared<DataArraySlice>(metaFile, sizeof(hdr)), res.hashLevelsSkipped);
	res.atoms = hdr.atoms();

	return res;
}

AssetMeta store::openV2AssetMeta ( const boost::filesystem::path& path ) {
	auto file = boost::make_shared<RandomAccessFile>( path, RandomAccessFile::READWRITE);

	V2Header hdr;
        if (file->size() < sizeof(hdr))
                throw ios_base::failure("File size less than constant header "+path.string());
	if (file->read(0, sizeof(hdr), (byte*)&hdr) != sizeof(hdr))
		throw ios_base::failure("Failed to read V2 header from "+path.string());
	if ((hdr.format != FileFormatVersion::V2CACHE) && (hdr.format != FileFormatVersion::V2LINKED))
		throw ios_base::failure("Unknown format of file "+path.string());

	uint64_t metaSize = HashStore::size_needed_for_atoms(hdr.atoms(), hdr.hashLevelsSkipped);

	AssetMeta res;
	res.hashLevelsSkipped = hdr.hashLevelsSkipped;
	res.hashStore = boost::make_shared<HashStore>(boost::make_shared<DataArraySlice>(file, sizeof(hdr), metaSize ), res.hashLevelsSkipped);
	res.tail = boost::make_shared<DataArraySlice>(file, sizeof(hdr) + metaSize);
	res.atoms = hdr.atoms();

	return res;
}

AssetMeta store::createAssetMeta ( const boost::filesystem::path& path, FileFormatVersion version, uint64_t dataSize, uint8_t levelsSkipped, uint64_t tailSize ) {
	uint64_t atoms = HashStore::atoms_needed_for_content(dataSize);
	uint64_t hashesSize = HashStore::size_needed_for_atoms(atoms, levelsSkipped);

	if ((version != store::V2CACHE) && (version != store::V2LINKED))
		throw std::invalid_argument("Failed to write header to "+path.native());

	auto file = boost::make_shared<RandomAccessFile>(path, RandomAccessFile::READWRITE, sizeof(V2Header) + hashesSize + tailSize);

	V2Header hdr;
	hdr.format = version;
	hdr.atoms(atoms);
	hdr.hashLevelsSkipped = levelsSkipped;
	if (file->write(0, &hdr, sizeof(hdr)) != sizeof(hdr))
		throw ios_base::failure("Failed to write header to "+path.native());

	auto hashSlice = boost::make_shared<DataArraySlice>(file, sizeof(hdr), hashesSize);

	AssetMeta res;
	res.hashLevelsSkipped = levelsSkipped;
	res.hashStore = boost::make_shared<HashStore>(hashSlice, res.hashLevelsSkipped);
	res.tail = boost::make_shared<DataArraySlice>(file, sizeof(hdr)+hashesSize);
	res.atoms = atoms;

	BOOST_ASSERT(res.tail->size() == tailSize);

	return res;
}
