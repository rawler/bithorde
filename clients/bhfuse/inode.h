#ifndef INODE_H
#define INODE_H

#include <atomic>
#include <map>
#include <sys/stat.h>

#include <boost/asio/deadline_timer.hpp>

#include <fuse_lowlevel.h>

#include "lib/asset.h"
#include "lib/types.h"

#include "lookup.h"

class BHFuse;

class INode {
public:
	BHFuse * fs;

	// Counts references held to this INode.
	std::atomic<int> _refCount;

	LookupParams lookup_params;

	fuse_ino_t nr;
	uint64_t size;

	INode(BHFuse * fs, fuse_ino_t ino, LookupParams& lookup_params);
	virtual ~INode();
	void takeRef();

	/**
	* Returns true if there are still references left to this asset.
	*/
	bool dropRefs(int count);

	bool fuse_reply_lookup(fuse_req_t req);
	bool fuse_reply_stat(fuse_req_t req);
protected:
	virtual void fill_stat_t(struct stat & s) = 0;
};

struct BHReadOperation {
	fuse_req_t req;
	off_t off;
	size_t size;

	BHReadOperation();
	BHReadOperation(fuse_req_t req, off_t off, size_t size);
};

class FUSEAsset : public INode, public boost::signals::trackable {
public:
	FUSEAsset(BHFuse *fs, fuse_ino_t ino, ReadAsset * asset, LookupParams& lookup_params);
	virtual ~FUSEAsset();

	ReadAsset * asset;

	void fuse_dispatch_open(fuse_req_t req, fuse_file_info * fi);
	void fuse_dispatch_close(fuse_req_t req, fuse_file_info * fi);
	void fuse_reply_open(fuse_req_t req, fuse_file_info * fi);

	void read(fuse_req_t req, off_t off, size_t size);
protected:
	virtual void fill_stat_t(struct stat & s);
private:
	void onDataArrived(uint64_t offset, ByteArray& data, int tag);
	void onStatusChanged(const bithorde::AssetStatus& s);
	void tryRebind();
	void closeOne();
private:
	// Counter to determine whether the underlying asset needs to be held open.
	std::atomic<int> _openCount;
	boost::asio::deadline_timer _holdOpenTimer;
	boost::asio::deadline_timer _rebindTimer;
	std::map<off_t, BHReadOperation> _readOperations;
	bool _connected;
};

#endif // INODE_H
