#ifndef MAIN_H
#define MAIN_H

#include <boost/asio.hpp>

#include <lib/bithorde.h>

#include "fuse++.hpp"
#include "inode.h"
#include "lookup.h"

class BHFuse : public BoostAsioFilesystem {
public:
	BHFuse(boost::asio::io_service & ioSvc, std::string bithorded, BoostAsioFilesystem_Options & opts);

    virtual void fuse_init(fuse_conn_info* conn);
	virtual int fuse_lookup(fuse_req_t req, fuse_ino_t parent, const char *name);
	virtual void fuse_forget(fuse_ino_t ino, u_long nlookup);
	virtual int fuse_getattr(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi);
	virtual int fuse_open(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi);
	virtual int fuse_release(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi);
	virtual int fuse_read(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, fuse_file_info *fi);

	bithorde::Client::Pointer client;
	boost::asio::io_service& ioSvc;
	std::string bithorded;

public:
	void onConnected(std::string remoteName);
	FUSEAsset * registerAsset(boost::shared_ptr< bithorde::ReadAsset > asset, LookupParams& lookup_params);
	void reconnect();

private:
	bool unrefInode(fuse_ino_t ino, int count);

	std::map<fuse_ino_t, INode::Ptr> _inode_cache;
	std::map<LookupParams, INode::Ptr> _lookup_cache;

	CachedAllocator<fuse_ino_t> _ino_allocator;
};

#endif // MAIN_H
