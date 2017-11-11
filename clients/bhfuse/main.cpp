#include "main.h"

#include <boost/log/trivial.hpp>
#include <boost/program_options.hpp>
#include <errno.h>
#include <signal.h>

#include <fuse/fuse_common.h>

#include "buildconf.hpp"
#include "lib/bithorde.h"

const int RECONNECT_ATTEMPTS = 30;
const int RECONNECT_INTERVAL_MS = 500;

using namespace std;
namespace asio = boost::asio;
namespace po = boost::program_options;

static asio::io_service ioSvc;

using namespace bithorde;

bool terminating = false;
void sigint(int sig) {
	BOOST_LOG_TRIVIAL(info) << "Intercepted signal#" << sig;
	if (sig == SIGINT || sig == SIGTERM) {
		if (terminating) {
			BOOST_LOG_TRIVIAL(info) << "Force Exiting...";
			exit(-1);
		} else {
			terminating = true;
			BOOST_LOG_TRIVIAL(info) << "Cleanly Exiting...";
			ioSvc.stop();
		}
	}
}

int main(int argc, char *argv[])
{
	signal(SIGINT, &sigint);

	BHFuseOptions opts;

	po::options_description desc("Supported options");
	desc.add_options()
		("help,h",
			"Show help")
		("version,v",
			"Show version")
		("name,n", po::value< string >()->default_value("bhget"),
			"Bithorde-name of this client")
		("debug,d",
			"Show fuse-commands, for debugging purposes")
		("url,u", po::value< string >()->default_value(BITHORDED_DEFAULT_UNIX_SOCKET),
			"Where to connect to bithorde. Either host:port, or /path/socket")
		("mountpoint", po::value< string >(&opts.mountpoint),
			"Where to mount filesystem")
		("blocksize", po::value< int >(&opts.blockSize)->default_value(32),
			"Blocksize in KB.")
		("readahead", po::value< int >(&opts.readAheadKB)->default_value(-1),
			"Amount to let the kernel pre-load, in KB. -1 means use automatic value")
		("timeout", po::value< int >(&opts.assetTimeoutMs)->default_value(1000),
			"How many millisecond to wait for assets to be found.")
	;
	po::positional_options_description p;
	p.add("mountpoint", 1);

	po::command_line_parser parser(argc, argv);
	parser.options(desc).positional(p);

	po::variables_map vm;
	po::store(parser.run(), vm);
	po::notify(vm);

	if (vm.count("version"))
		return bithorde::exit_version();

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

FUSEAsset::Ptr INodeCache::lookup(const bithorde::Ids& ids)
{
	for (auto iter=begin(); iter != end(); iter++) {
		if (auto asset=dynamic_pointer_cast<FUSEAsset>(iter->second)) {
			if (idsOverlap(ids, asset->asset->confirmedIds())) {
				return asset;
			}
		}
	}
	return FUSEAsset::Ptr();
}

BHFuse::BHFuse(asio::io_service& ioSvc, string bithorded, const BHFuseOptions& opts) :
	BoostAsioFilesystem(ioSvc, opts),
	ioSvc(ioSvc),
	bithorded(bithorded),
	opts(opts),
	_timerSvc(std::make_shared<TimerService>(ioSvc)),
	_ino_allocator(2)
{
	client = Client::create(ioSvc, "bhfuse");

	client->authenticated.connect([=](bithorde::Client& c, std::string remoteName) {
		if (remoteName.empty()) {
			(cerr << "Failed authentication" << endl).flush();
			this->ioSvc.stop();
		} else {
			(cerr << "Connected to " << remoteName << endl).flush();
		}
	});

	client->disconnected.connect([=]() {
		reconnect();
	});

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

void BHFuse::onConnected(bithorde::Client&, std::string remoteName) {
}

void BHFuse::fuse_init(fuse_conn_info* conn)
{
	if (opts.readAheadKB >= 0)
		conn->max_readahead = opts.readAheadKB<<10;
}

int BHFuse::fuse_lookup(fuse_req_t req, fuse_ino_t parent, const char *name) {
	if (parent != 1)
		return ENOENT;

	LookupParams lp(parent, name);

	MagnetURI uri;
	if (uri.parse(name)) {
		auto ids = uri.toIdList();
		if (ids.size()) {
			if (auto asset = _inode_cache.lookup(ids)) {
				asset->fuse_reply_lookup(req);
			} else {
				Lookup * lookup = new Lookup(this, req, ids);
				lookup->perform(client);
			}
			return 0;
		}
	}
	return ENOENT;
}

void BHFuse::fuse_forget(fuse_ino_t ino, u_long nlookup) {
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
	FUSEAsset * a;
	if (_inode_cache.count(ino) && (a = dynamic_cast<FUSEAsset*>(_inode_cache[ino].get()))) {
		a->fuse_dispatch_open(req, fi);
		return 0;
	} else {
		return ENOENT;
	}
}

int BHFuse::fuse_release(fuse_req_t req, fuse_ino_t ino, fuse_file_info * fi) {
	if (FUSEAsset * a = dynamic_cast<FUSEAsset*>(_inode_cache[ino].get())) {
		a->fuse_dispatch_close(req, fi);
		return 0;
	} else {
		return EBADF;
	}
}

int BHFuse::fuse_read(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, fuse_file_info *)
{
	if (FUSEAsset* a = dynamic_cast<FUSEAsset*>(_inode_cache[ino].get())) {
		a->read(req, off, size);
		return 0;
	} else {
		return EBADF;
	}
}

FUSEAsset * BHFuse::registerAsset(std::shared_ptr< ReadAsset > asset)
{
	fuse_ino_t ino = _ino_allocator.allocate();
	FUSEAsset::Ptr a = FUSEAsset::create(this, ino, asset);
	_inode_cache[ino] = a;
	return static_cast<FUSEAsset*>(a.get());
}

TimerService& BHFuse::timerSvc()
{
	return *_timerSvc;
}

bool BHFuse::unrefInode(fuse_ino_t ino, int count)
{
	INode::Ptr i = _inode_cache[ino];
	if (i) {
		if (!i->dropRefs(count)) {
			_inode_cache.erase(ino);
			_ino_allocator.free(ino);
		}
		return true;
	} else {
		return false;
	}
}
