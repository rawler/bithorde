#include "main.h"
#include "inode.h"

#include <errno.h>
#include <iostream>

#include <lib/client.h>

using namespace std;
namespace asio = boost::asio;

INode::INode(BHFuse *fs, fuse_ino_t ino) :
	fs(fs),
	_refCount(1),
	nr(ino),
	size(0)
{
}

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
	e.attr_timeout = 5;
	e.entry_timeout = 3600;
	e.generation = 1;
	e.ino = nr;

	fuse_reply_entry(req, &e);
	return true;
}

bool INode::fuse_reply_stat(fuse_req_t req) {
	struct stat s;
	bzero(&s, sizeof(s));
	fill_stat_t(s);
	fuse_reply_attr(req, &s, 5);
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

FUSEAsset::FUSEAsset(BHFuse* fs, fuse_ino_t ino, ReadAsset* asset) :
	INode(fs, ino),
	asset(asset),
	_openCount(0),
	_holdOpenTimer(fs->ioSvc)
{
	size = asset->size();

	if (asset->isBound()) { // Schedule a delayed close of the initial reference.
		_openCount++;
		_holdOpenTimer.expires_from_now(boost::posix_time::milliseconds(200));
		_holdOpenTimer.async_wait(boost::bind(&FUSEAsset::closeOne, this));
	}

	asset->dataArrived.connect(boost::bind(&FUSEAsset::onDataArrived, this, _1, _2, _3));
}

void FUSEAsset::fuse_dispatch_open(fuse_req_t req, fuse_file_info * fi)
{
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
	_openCount++;
	_holdOpenTimer.cancel();
	fi->keep_cache = true;
	::fuse_reply_open(req, fi);
}

void FUSEAsset::read(fuse_req_t req, off_t off, size_t size)
{
	int tag = asset->aSyncRead(off, size);
	readOperations[tag] = BHReadOperation(req, off, size);
}

void FUSEAsset::fill_stat_t(struct stat &s) {
	s.st_mode = S_IFREG | 0555;
	s.st_ino = nr;
	s.st_size = size;
	s.st_nlink = 1;
}

void FUSEAsset::onDataArrived(uint64_t offset, ByteArray& data, int tag) {
	BHReadOperation &op = readOperations[tag];
	if (op.req) {
		if ((off_t)offset == op.off)
			fuse_reply_buf(op.req, (const char*)data.data(), data.size());
		else
			fuse_reply_err(op.req, EIO);
	} else {
		(cerr << "ERROR: got response for unknown request").flush();
	}
	readOperations.erase(tag);
}

void FUSEAsset::closeOne()
{
	if (!--_openCount)
		asset->close();
}
