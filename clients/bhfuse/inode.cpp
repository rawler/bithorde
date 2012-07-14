#include "main.h"
#include "inode.h"

#include <errno.h>
#include <iostream>

#include <lib/client.h>

static const uint ATTR_TIMEOUT = 2;
static const uint INODE_TIMEOUT = 4;
static const size_t BLOCK_SIZE = 64*1024;
static const uint REBIND_INTERVAL_MS = 1000;
static const uint READ_RETRIES = 5;

using namespace std;
namespace asio = boost::asio;

using namespace bithorde;

INode::INode(BHFuse* fs, ino_t ino, LookupParams& lookup_params) :
	_refCount(0),
	fs(fs),
	lookup_params(lookup_params),
	nr(ino),
	size(0)
{
}

INode::~INode() {
	BOOST_ASSERT(_refCount == 0);
}

void INode::takeRef() {
	_refCount++;
}

bool INode::dropRefs(int count) {
	return (_refCount -= count) > 0;
}

bool INode::fuse_reply_lookup(fuse_req_t req) {
	_refCount++;

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
	size(0),
	retries(0)
{}

BHReadOperation::BHReadOperation(fuse_req_t req, off_t off, size_t size) :
	req(req),
	off(off),
	size(size),
	retries(0)
{}

FUSEAsset::FUSEAsset(BHFuse* fs, ino_t ino, boost::shared_ptr< ReadAsset > asset, LookupParams& lookup_params) :
	INode(fs, ino, lookup_params),
	asset(asset),
	_openCount(0),
	_holdOpenTimer(fs->ioSvc),
	_rebindTimer(fs->ioSvc),
	_connected(true)
{
	size = asset->size();
}

void FUSEAsset::init()
{
	if (asset->isBound()) { // Schedule a delayed close of the initial reference.
		_openCount++;
		_holdOpenTimer.expires_from_now(boost::posix_time::milliseconds(200));
		_holdOpenTimer.async_wait(boost::bind(&FUSEAsset::closeOne, shared_from_this()));
	}

	_statusConnection = asset->statusUpdate.connect(Asset::StatusSignal::slot_type(&FUSEAsset::onStatusChanged, this, ASSET_ARG_STATUS));
	_dataConnection = asset->dataArrived.connect(ReadAsset::DataSignal::slot_type(&FUSEAsset::onDataArrived, this, ASSET_ARG_OFFSET, ASSET_ARG_DATA, ASSET_ARG_TAG));
}

FUSEAsset::~FUSEAsset()
{
	_holdOpenTimer.cancel();
	_rebindTimer.cancel();
	BOOST_ASSERT(_openCount == 0);
}

FUSEAsset::Ptr FUSEAsset::create(BHFuse* fs, ino_t ino, boost::shared_ptr< ReadAsset > asset, LookupParams& lookup_params)
{
	FUSEAsset *a = new FUSEAsset(fs, ino, asset, lookup_params);
	Ptr p(a);
	a->init();
	return p;
}

void FUSEAsset::fuse_dispatch_open(fuse_req_t req, fuse_file_info * fi)
{
	_openCount++;
	if (asset && asset->isBound()) {
		this->fuse_reply_open(req);
	} else {
		Ptr self = shared_from_this();
		Lookup * l = new Lookup(fs, self, req);
		l->perform(fs->client);
	}
}

void FUSEAsset::fuse_dispatch_close(fuse_req_t req, fuse_file_info *) {
	closeOne();
	fuse_reply_err(req, 0);
}

void FUSEAsset::fuse_reply_open(fuse_req_t req) {
	fuse_file_info fi;
	bzero(&fi, sizeof(fuse_file_info));
	fi.flush = false;
	fi.keep_cache = true;
	fi.nonseekable = false;
	::fuse_reply_open(req, &fi);
}

void FUSEAsset::read(fuse_req_t req, off_t off, size_t size)
{
	if (off >= (off_t)this->size) {
		fuse_reply_buf(req, 0, 0);
	} else {
		queueRead(BHReadOperation(req,off,size));
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
	if (fs->debug) {
		cerr << "BHFUSE:" << nr << ": statusUpdate " << bithorde::Status_Name(s.status()) << endl;
	}
	switch (s.status()) {
	case bithorde::SUCCESS:
		if (!_connected) {
			_connected = true;
			map<off_t, BHReadOperation> oldReads = _readOperations;
			_readOperations.clear();
			for (auto iter = oldReads.begin(); iter != oldReads.end(); iter++) {
				queueRead(iter->second);
			}
		}
		break;
	case bithorde::NOTFOUND:
	case bithorde::INVALID_HANDLE:
		if (fs->client->isConnected()) {
			_rebindTimer.expires_from_now(boost::posix_time::milliseconds(REBIND_INTERVAL_MS));
			_rebindTimer.async_wait(boost::bind(&FUSEAsset::tryRebind, shared_from_this()));
		}

	default:
		_connected = false;
	}
}

void FUSEAsset::queueRead(const BHReadOperation& read)
{
	int tag = 0;
	if (_connected) {
		tag = asset->aSyncRead(read.off, read.size);
	} else {
		do {
			tag++;
		} while (_readOperations.count(tag)); // Just find a tag to hook it on
	}
	auto& op = _readOperations[tag] = read;
	op.retries++;
}

void FUSEAsset::tryRebind()
{
	if (fs->client->isConnected()) {
		fs->client->bind(*asset);
	} else {
		_rebindTimer.expires_from_now(boost::posix_time::milliseconds(REBIND_INTERVAL_MS));
		_rebindTimer.async_wait(boost::bind(&FUSEAsset::tryRebind, shared_from_this()));
	}
}

void FUSEAsset::onDataArrived(uint64_t offset, const std::string& data, int tag) {
	if (_readOperations.count(tag)) {
		BHReadOperation &op = _readOperations[tag];
		if (_connected) {
			if (data.empty()) {
				BHReadOperation opCopy = op;
				_readOperations.erase(tag);
				if (op.retries < READ_RETRIES)
					queueRead(opCopy);
				else
					fuse_reply_err(op.req, EIO);
			} else {
				if ((off_t)offset == op.off)
					fuse_reply_buf(op.req, (const char*)data.data(), data.size());
				else
					fuse_reply_err(op.req, EIO);
				_readOperations.erase(tag);
			}
		} // else wait for reconnection
	} else {
		(cerr << "ERROR: got response for unknown request " << tag << endl).flush();
	}
}

void FUSEAsset::closeOne()
{
	if ((--_openCount) <= 0) {
		_rebindTimer.cancel();
		asset->close();
		for (auto iter = _readOperations.begin(); iter != _readOperations.end(); iter++) {
			fuse_reply_err(iter->second.req, EIO);
		}
		_readOperations.clear();
	}
}
