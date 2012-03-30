#include "main.h"
#include "inode.h"

#include <errno.h>
#include <iostream>

#include <lib/client.h>

static const int ATTR_TIMEOUT = 2;
static const int INODE_TIMEOUT = 4;
static const int BLOCK_SIZE = 64*1024;
static const int REBIND_INTERVAL_MS = 500;

using namespace std;
namespace asio = boost::asio;

using namespace bithorde;

INode::INode(BHFuse *fs, fuse_ino_t ino, LookupParams& lookup_params) :
	fs(fs),
	_refCount(1),
	lookup_params(lookup_params),
	nr(ino),
	size(0)
{
}

INode::~INode() {}

void INode::takeRef() {
	_refCount++;
}

bool INode::dropRefs(int count) {
	return (_refCount -= count) > 0;
}

bool INode::fuse_reply_lookup(fuse_req_t req) {
	fuse_entry_param e;
	bzero(&e, sizeof(e));
	fill_stat_t(e.attr);
	e.attr_timeout = ATTR_TIMEOUT;
	e.entry_timeout = INODE_TIMEOUT;
	e.generation = 1;
	e.ino = nr;

	fuse_reply_entry(req, &e);
	return true;
}

bool INode::fuse_reply_stat(fuse_req_t req) {
	struct stat s;
	bzero(&s, sizeof(s));
	fill_stat_t(s);
	fuse_reply_attr(req, &s, ATTR_TIMEOUT);
	return true;
}

BHReadOperation::BHReadOperation() :
	req(NULL),
	off(-1),
	size(0)
{}

BHReadOperation::BHReadOperation(fuse_req_t req, off_t off, size_t size) :
	req(req),
	off(off),
	size(size)
{}

FUSEAsset::FUSEAsset(BHFuse* fs, fuse_ino_t ino, ReadAsset* asset, LookupParams& lookup_params) :
	INode(fs, ino, lookup_params),
	asset(asset),
	_openCount(0),
	_holdOpenTimer(fs->ioSvc),
	_rebindTimer(fs->ioSvc),
	_connected(true)
{
	size = asset->size();

	if (asset->isBound()) { // Schedule a delayed close of the initial reference.
		_openCount++;
		_holdOpenTimer.expires_from_now(boost::posix_time::milliseconds(200));
		_holdOpenTimer.async_wait(boost::bind(&FUSEAsset::closeOne, this));
	}

	asset->statusUpdate.connect(boost::bind(&FUSEAsset::onStatusChanged, this, Asset::STATUS));
	asset->dataArrived.connect(boost::bind(&FUSEAsset::onDataArrived, this, ReadAsset::OFFSET, ReadAsset::DATA, ReadAsset::TAG));
}


FUSEAsset::~FUSEAsset()
{
	_holdOpenTimer.cancel();
	_rebindTimer.cancel();
	BOOST_ASSERT(_refCount == 0);
	BOOST_ASSERT(_openCount == 0);
}

void FUSEAsset::fuse_dispatch_open(fuse_req_t req, fuse_file_info * fi)
{
	_openCount++;
	_holdOpenTimer.cancel(); // TODO: potential race-condition, if timeout has already been scheduled for this round
	if (asset && asset->isBound()) {
		this->fuse_reply_open(req, fi);
	} else {
		Lookup * l = new Lookup(fs, this, req, fi);
		l->perform(fs->client);
	}
}

void FUSEAsset::fuse_dispatch_close(fuse_req_t req, fuse_file_info *) {
	closeOne();
	fuse_reply_err(req, 0);
}

void FUSEAsset::fuse_reply_open(fuse_req_t req, fuse_file_info * fi) {
	fi->flush = false;
	fi->keep_cache = true;
	fi->nonseekable = false;
	::fuse_reply_open(req, fi);
}

void FUSEAsset::read(fuse_req_t req, off_t off, size_t size)
{
	if (off >= (off_t)this->size) {
		fuse_reply_buf(req, 0, 0);
	} else {
		int tag = asset->aSyncRead(off, size);
		_readOperations[tag] = BHReadOperation(req, off, size);
	}
}

void FUSEAsset::fill_stat_t(struct stat &s) {
	s.st_mode = S_IFREG | 0555;
	s.st_blksize = BLOCK_SIZE;
	s.st_ino = nr;
	s.st_size = size;
	s.st_nlink = 1;
}

void FUSEAsset::onStatusChanged(const bithorde::AssetStatus& s)
{
	switch (s.status()) {
	case bithorde::SUCCESS:
		if (!_connected) {
			map<off_t, BHReadOperation> oldReads = _readOperations;
			_readOperations.clear();
			for (auto iter = oldReads.begin(); iter != oldReads.end(); iter++) {
				int tag = asset->aSyncRead(iter->second.off, iter->second.size);
				_readOperations[tag] = iter->second;
			}
			_connected = true;
		}
		break;
	case bithorde::NOTFOUND:
	case bithorde::INVALID_HANDLE:
		if (fs->client->isConnected()) {
			_rebindTimer.expires_from_now(boost::posix_time::milliseconds(REBIND_INTERVAL_MS));
			_rebindTimer.async_wait(boost::bind(&FUSEAsset::tryRebind, this));
		}

	default:
		_connected = false;
	}
}

void FUSEAsset::tryRebind()
{
	if (fs->client->isConnected()) {
		fs->client->bind(*asset);
	} else {
		_rebindTimer.expires_from_now(boost::posix_time::milliseconds(REBIND_INTERVAL_MS));
		_rebindTimer.async_wait(boost::bind(&FUSEAsset::tryRebind, this));
	}
}

void FUSEAsset::onDataArrived(uint64_t offset, ByteArray& data, int tag) {
	if (_readOperations.count(tag)) {
		BHReadOperation &op = _readOperations[tag];
		if (_connected) {
			if ((off_t)offset == op.off)
				fuse_reply_buf(op.req, (const char*)data.data(), data.size());
			else
				fuse_reply_err(op.req, EIO);
			_readOperations.erase(tag);
		} // else wait for reconnection
	} else {
		(cerr << "ERROR: got response for unknown request").flush();
	}
}

void FUSEAsset::closeOne()
{
	if (!--_openCount) {
		_rebindTimer.cancel();
		asset->close();
		for (auto iter = _readOperations.begin(); iter != _readOperations.end(); iter++) {
			fuse_reply_err(iter->second.req, EIO);
		}
		_readOperations.clear();
	}
}
