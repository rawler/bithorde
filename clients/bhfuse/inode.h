#ifndef INODE_H
#define INODE_H

#include <atomic>
#include <map>
#include <sys/stat.h>

#include "lib/asset.h"
#include "lib/timer.h"
#include "lib/types.h"

#include "lookup.h"

class BHFuse;

class INode {
	// Counts references held to this INode. TODO: break out of INode alltogether.
	std::atomic<int> _refCount;

public:
	typedef boost::shared_ptr<INode> Ptr;

	BHFuse * fs;

	fuse_ino_t nr;
	uint64_t size;

	INode(BHFuse* fs, ino_t ino);
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
	uint retries;

	BHReadOperation();
	BHReadOperation(fuse_req_t req, off_t off, size_t size);
};

class FUSEAsset : public INode, public boost::enable_shared_from_this<FUSEAsset> {
	FUSEAsset(BHFuse* fs, ino_t ino, boost::shared_ptr< bithorde::ReadAsset > asset);
public:
	typedef boost::shared_ptr<FUSEAsset> Ptr;

	static Ptr create(BHFuse* fs, ino_t ino, boost::shared_ptr< bithorde::ReadAsset > asset);

	boost::shared_ptr<bithorde::ReadAsset> asset;

	void fuse_dispatch_open(fuse_req_t req, fuse_file_info * fi);
	void fuse_dispatch_close( fuse_req_t req, fuse_file_info*);
	void fuse_reply_open(fuse_req_t req);

	void read(fuse_req_t req, off_t off, size_t size);
protected:
	virtual void fill_stat_t(struct stat & s);
private:
	void onDataArrived(uint64_t offset, const std::string& data, int tag);
	void onStatusChanged(const bithorde::AssetStatus& s);
	void queueRead(const BHReadOperation& read);
	void tryRebind();
	void closeOne();
private:
	// Counter to determine whether the underlying asset needs to be held open.
	std::atomic<int> _openCount;
	Timer _holdOpenTimer;
	Timer _rebindTimer;
	std::map<off_t, BHReadOperation> _readOperations;
	bool _connected;
	uint16_t _retries;

	boost::signals2::scoped_connection _statusConnection;
	boost::signals2::scoped_connection _dataConnection;
};

#endif // INODE_H
