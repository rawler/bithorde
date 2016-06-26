#include "fuse++.hpp"

#include <alloca.h>
#include <errno.h>
#include <iostream>

#include <boost/assert.hpp>

#include <fuse_lowlevel.h>
#include <fuse_opt.h>

using namespace std;
namespace asio = boost::asio;

extern "C" {
    // C++-wrappers to map fuse_userdata to a specific FileSystem. Also ensures fuse gets
    // an error if an Exception aborts control.
    static void _op_init(void *userdata, struct fuse_conn_info *conn) {
        static_cast<BoostAsioFilesystem*>(userdata)->fuse_init(conn);
    }
    static void _op_lookup(fuse_req_t req, fuse_ino_t parent, const char *name) {
        int res = ((BoostAsioFilesystem*)fuse_req_userdata(req))->fuse_lookup(req, parent, name);
        if (res)
            fuse_reply_err(req, res);
    }
    static void _op_forget(fuse_req_t req, fuse_ino_t ino, u_long nlookup) {
        ((BoostAsioFilesystem*)fuse_req_userdata(req))->fuse_forget(ino, nlookup);
        fuse_reply_none(req);
    }
    static void _op_getattr(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) {
        int res = ((BoostAsioFilesystem*)fuse_req_userdata(req))->fuse_getattr(req, ino, fi);
        if (res)
            fuse_reply_err(req, res);
    }
    static void _op_open(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) {
        int res = ((BoostAsioFilesystem*)fuse_req_userdata(req))->fuse_open(req, ino, fi);
        if (res)
            fuse_reply_err(req, res);
    }
    static void _op_release(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) {
        int res = ((BoostAsioFilesystem*)fuse_req_userdata(req))->fuse_release(req, ino, fi);
        if (res)
            fuse_reply_err(req, res);
    }
    static void _op_read(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, fuse_file_info *fi) {
        int res = ((BoostAsioFilesystem*)fuse_req_userdata(req))->fuse_read(req, ino, size, off, fi);
        if (res)
            fuse_reply_err(req, res);
    }
}

BoostAsioFilesystem_Options::BoostAsioFilesystem_Options()
	: mountpoint(""), debug(false)
{
	this->insert(value_type("max_read", "65536"));
	this->insert(value_type("asyncRead", ""));
	this->insert(value_type("allow_other", ""));
}

void BoostAsioFilesystem_Options::format_ll_opts(vector< string >& target) const {
	target.push_back(name);
	target.push_back("-ofsname="+name);

	if (debug) {
		target.push_back("-d");
	}
	for (auto iter = begin(); iter != end(); iter++) {
		ostringstream oss;
		oss << "-o" << iter->first;
		if (iter->second.length())
			oss << '=' << iter->second;
		target.push_back(oss.str());
	}
	target.insert(target.end(), args.begin(), args.end());
}

BoostAsioFilesystem::BoostAsioFilesystem(asio::io_service& ioSvc, const BoostAsioFilesystem_Options& options)
	: _channel(ioSvc), _mountpoint(options.mountpoint), _fuse_chan(0), _fuse_session(0)
{
	vector<string> opts;
	options.format_ll_opts(opts);
	debug = options.debug;

	uint16_t argc = opts.size();
	char** argv = (char**)malloc(argc * sizeof(char*));
	for (int i=0; i < argc; i++)
		argv[i] = strdup(opts[i].c_str());

	fuse_args f_args = FUSE_ARGS_INIT(argc, argv);
	_fuse_chan = fuse_mount(_mountpoint.c_str(), &f_args);
	if (!_fuse_chan)
		throw string("Failed to mount");

	_channel.assign(fuse_chan_fd(_fuse_chan));

	/************************************************************************************
	* FUSE_lowlevel_ops struct, pointing to the C++-class-wrappers.
	***********************************************************************************/
	static fuse_lowlevel_ops bfs_ops;
	bzero(&bfs_ops, sizeof(bfs_ops));
	bfs_ops.init =    _op_init;
	bfs_ops.lookup =  _op_lookup;
	bfs_ops.forget =  _op_forget;
	bfs_ops.getattr = _op_getattr;
	bfs_ops.open =    _op_open;
	bfs_ops.read =    _op_read;
	bfs_ops.release = _op_release;

	_fuse_session = fuse_lowlevel_new(&f_args, &bfs_ops, sizeof(bfs_ops), this);
	// scope(failure)fuse_session_destroy(s);

	fuse_session_add_chan(_fuse_session, _fuse_chan);

	_receive_buf.allocate(fuse_chan_bufsize(_fuse_chan));
	readNext();
}

BoostAsioFilesystem::~BoostAsioFilesystem() {
	if (_fuse_chan)
		fuse_unmount(_mountpoint.c_str(), _fuse_chan);
	if (_fuse_session)
		fuse_session_destroy(_fuse_session);
}

void BoostAsioFilesystem::readNext()
{
	_channel.async_read_some(
		asio::buffer(_receive_buf.ptr, _receive_buf.capacity),
		[=](const boost::system::error_code& ec, size_t count) {
            if (ec) {
                cerr << "ERROR reading from fuse: " << ec.message() << endl;
            } else {
                fuse_session_process(_fuse_session, (const char*)_receive_buf.ptr, count, _fuse_chan);
                readNext();
            }
        }
	);
}

