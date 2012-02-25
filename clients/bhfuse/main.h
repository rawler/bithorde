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

	virtual int fuse_lookup(fuse_req_t req, fuse_ino_t parent, const char *name);
	virtual void fuse_forget(fuse_ino_t ino, ulong nlookup);
	virtual int fuse_getattr(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi);
	virtual int fuse_open(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi);
	virtual int fuse_release(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi);
	virtual int fuse_read(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, fuse_file_info *fi);

	Client::Pointer client;
	boost::asio::io_service& ioSvc;

public:
	void onConnected(std::string remoteName);
	FUSEAsset * registerAsset(ReadAsset * asset);

private:
	bool unrefInode(fuse_ino_t ino, int count);

	std::map<fuse_ino_t, INode *> inode_cache;
	CachedAllocator<fuse_ino_t> ino_allocator;
};

#endif // MAIN_H
