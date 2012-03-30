#include "main.h"

#include <boost/program_options.hpp>
#include <errno.h>
#include <signal.h>

const int RECONNECT_ATTEMPTS = 30;
const int RECONNECT_INTERVAL_MS = 500;

using namespace std;
namespace asio = boost::asio;
namespace po = boost::program_options;

static asio::io_service ioSvc;

using namespace bithorde;

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

	BoostAsioFilesystem_Options opts;

	po::options_description desc("Supported options");
	desc.add_options()
		("help,h",
			"Show help")
		("name,n", po::value< string >()->default_value("bhget"),
			"Bithorde-name of this client")
		("debug,d",
			"Show fuse-commands, for debugging purposes")
		("url,u", po::value< string >()->default_value("/tmp/bithorde"),
			"Where to connect to bithorde. Either host:port, or /path/socket")
		("mountpoint", po::value< string >(&opts.mountpoint), 
			"Where to mount filesystem")
	;
	po::positional_options_description p;
	p.add("mountpoint", 1);

	po::command_line_parser parser(argc, argv);
	parser.options(desc).positional(p);

	po::variables_map vm;
	po::store(parser.run(), vm);
	po::notify(vm);

	if (vm.count("help") || !vm.count("mountpoint")) {
		cerr << desc << endl;
		return 1;
	}

	opts.name = "bhfuse";
	if (vm.count("debug"))
		opts.debug = true;

	BHFuse fs(ioSvc, vm["url"].as<string>(), opts);

	return ioSvc.run();
}

BHFuse::BHFuse(asio::io_service & ioSvc, string bithorded, BoostAsioFilesystem_Options & opts) :
	BoostAsioFilesystem(ioSvc, opts),
	ioSvc(ioSvc),
	bithorded(bithorded),
	_ino_allocator(2)
{
	client = Client::create(ioSvc, "bhfuse");
	client->authenticated.connect(boost::bind(&BHFuse::onConnected, this, _1));
	client->disconnected.connect(boost::bind(&BHFuse::reconnect, this));

	client->connect(bithorded);
}

void BHFuse::reconnect()
{
	cerr << "Disconnected, trying reconnect..." << endl;
	for (int i=0; i < RECONNECT_ATTEMPTS; i++) {
		usleep(RECONNECT_INTERVAL_MS * 1000);
		try {
			client->connect(bithorded);
			return;
		} catch (boost::system::system_error e) {
			cerr << "Failed to reconnect, retrying..." << endl;
		}
	}
	cerr << "Giving up." << endl;
	ioSvc.stop();
}

void BHFuse::onConnected(std::string remoteName) {
	(cout << "Connected to " << remoteName << endl).flush();
}

int BHFuse::fuse_lookup(fuse_req_t req, fuse_ino_t parent, const char *name) {
	if (parent != 1)
		return ENOENT;

	LookupParams lp(parent, name);
	if (_lookup_cache.count(lp)) {
		_lookup_cache[lp]->fuse_reply_lookup(req);
		return 0;
	}

	MagnetURI uri;
	if (uri.parse(name)) {
		Lookup * lookup = new Lookup(this, req, uri, lp);
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
	} else if (_inode_cache.count(ino)) {
		_inode_cache[ino]->fuse_reply_stat(req);
	} else {
		return ENOENT;
	}
	return 0;
}

int BHFuse::fuse_open(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) {
	FUSEAsset* a;
	if (_inode_cache.count(ino) && (a = dynamic_cast<FUSEAsset*>(_inode_cache[ino]))) {
		a->fuse_dispatch_open(req, fi);
		return 0;
	} else {
		return ENOENT;
	}
}

int BHFuse::fuse_release(fuse_req_t req, fuse_ino_t ino, fuse_file_info * fi) {
	if (FUSEAsset * a = static_cast<FUSEAsset*>(_inode_cache[ino])) {
		a->fuse_dispatch_close(req, fi);
		return 0;
	} else {
		return EBADF;
	}
}

int BHFuse::fuse_read(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, fuse_file_info *)
{
	FUSEAsset* a = dynamic_cast<FUSEAsset*>(_inode_cache[ino]);
	if (a) {
		a->read(req, off, size);
		return 0;
	} else {
		return EBADF;
	}
}

FUSEAsset * BHFuse::registerAsset(ReadAsset *asset, LookupParams& lookup_params)
{
	fuse_ino_t ino = _ino_allocator.allocate();
	FUSEAsset * a = new FUSEAsset(this, ino, asset, lookup_params);
	_inode_cache[ino] = a;
	_lookup_cache[lookup_params] = a;
	return a;
}

bool BHFuse::unrefInode(fuse_ino_t ino, int count)
{
	INode * i = _inode_cache[ino];
	if (i) {
		if (!i->dropRefs(count)) {
			_inode_cache.erase(ino);
			_lookup_cache.erase(i->lookup_params);
			_ino_allocator.free(ino);
			delete i;
		}
		return true;
	} else {
		return false;
	}
}
