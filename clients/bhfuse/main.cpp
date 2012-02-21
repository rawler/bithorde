#include "main.h"

#include <signal.h>
#include <errno.h>

using namespace std;
namespace asio = boost::asio;

static const string UNIX_SOCK_PATH("/tmp/bithorde");
static const string mountPoint("/tmp/bhfuse");

static asio::io_service ioSvc;

void sigint(int sig) {
	cerr << "Intercepted signal#" << sig << endl;
	if (sig == SIGINT) {
		cerr << "Exiting..." << endl;
		ioSvc.stop();
		// TODO: Emergency exit on repeated sig
	}
	cerr.flush();
}

int main(int argc, char *argv[])
{
	signal(SIGINT, &sigint);

	vector<string> args;
	args.push_back("-v");
	args.push_back("-d");

	BHFuse fs(ioSvc, mountPoint, args);

	return ioSvc.run();
}

BHFuse::BHFuse(asio::io_service& ioSvc, std::string mountPoint, std::vector< std::string > args) :
	BoostAsioFilesystem(ioSvc, mountPoint, args),
	ioSvc(ioSvc),
	ino_allocator(2)
{
	asio::local::stream_protocol::endpoint bithorded(UNIX_SOCK_PATH);
	Connection::Pointer connection = Connection::create(ioSvc, bithorded);
	client = Client::create(connection, "bhfuse");
	client->authenticated.connect(boost::bind(&BHFuse::onConnected, this, _1));
}

void BHFuse::onConnected(std::string remoteName) {
	(cout << "Connected to " << remoteName << endl).flush();
}

int BHFuse::fuse_lookup(fuse_req_t req, fuse_ino_t parent, const char *name) {
	if (parent != 1)
		return ENOENT;

	MagnetURI uri;
	if (uri.parse(name)) {
		Lookup * lookup = new Lookup(this, req, uri);
		lookup->perform(client);
		return 0;
	} else {
		return ENOENT;
	}
}

void BHFuse::fuse_forget(fuse_ino_t ino, ulong nlookup) {
	unrefInode(ino, nlookup);
}

int BHFuse::fuse_getattr(fuse_req_t req, fuse_ino_t ino, fuse_file_info *) {
	if (ino == 1) {
		struct stat attr;
		bzero(&attr, sizeof(attr));
		attr.st_mode = S_IFDIR | 0444;
		attr.st_blksize = 32*1024;
		attr.st_ino = ino;
		attr.st_nlink = 2;
		fuse_reply_attr(req, &attr, 5);
	} else if (inode_cache.count(ino)) {
		inode_cache[ino]->fuse_reply_stat(req);
	} else {
		return ENOENT;
	}
	return 0;
}

int BHFuse::fuse_open(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) {
	FUSEAsset* a = static_cast<FUSEAsset*>(inode_cache[ino]);
	if (a) {
		a->fuse_dispatch_open(req, fi);
		return 0;
	} else {
		return ENOENT;
	}
}

int BHFuse::fuse_release(fuse_req_t req, fuse_ino_t ino, fuse_file_info * fi) {
	if (FUSEAsset * a = static_cast<FUSEAsset*>(inode_cache[ino])) {
		a->fuse_dispatch_close(req, fi);
		return 0;
	} else {
		return EBADF;
	}
}

int BHFuse::fuse_read(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, fuse_file_info *)
{
	FUSEAsset* a = static_cast<FUSEAsset*>(inode_cache[ino]);
	if (a) {
		(cerr << "Reading..." << endl).flush();
		a->read(req, off, size);
		return 0;
	} else {
		return EBADF;
	}
}

FUSEAsset * BHFuse::registerAsset(ReadAsset *asset)
{
	fuse_ino_t ino = ino_allocator.allocate();
	FUSEAsset * a = new FUSEAsset(this, ino, asset);
	inode_cache[ino] = a;
	return a;
}

bool BHFuse::unrefInode(fuse_ino_t ino, int count)
{
	INode * i = inode_cache[ino];
	if (i) {
		if (!i->dropRefs(count)) {
			inode_cache.erase(ino);
			delete i;
		}
		return true;
	} else {
		return false;
	}
}
