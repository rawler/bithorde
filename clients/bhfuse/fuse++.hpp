#ifndef FUSEPP_H
#define FUSEPP_H

#include <string>
#include <vector>

#include <boost/asio.hpp>

#define FUSE_USE_VERSION 26
#include <fuse_lowlevel.h>

#include <lib/types.h>

struct BoostAsioFilesystem_Options : public std::map<std::string, std::string> {
	std::string name;
	std::string mountpoint;
	bool debug;

	std::vector<std::string> args;

	BoostAsioFilesystem_Options();

	void format_ll_opts(std::vector<std::string>& target);
};

class BoostAsioFilesystem
{
	/****************************************************************************************
	* Abstract C++ class used to implement real FileSystems in a boost asynchronous manner.
	* Filesystem-implementations should extend this class, and implement each abstracted
	* method.
	***************************************************************************************/
public:
	BoostAsioFilesystem(boost::asio::io_service& ioSvc, BoostAsioFilesystem_Options& options);
	~BoostAsioFilesystem();

	/************************************************************************************
	* Initialize FUSE filesystem
	************************************************************************************/
	virtual void fuse_init(fuse_conn_info* conn) = 0;

	/************************************************************************************
	* FUSE-hook for mapping a name in a directory to an inode.
	***********************************************************************************/
	virtual int fuse_lookup(fuse_req_t req, fuse_ino_t parent, const char *name) = 0;

	/************************************************************************************
	* FUSE-hook informing that an INode may be forgotten
	***********************************************************************************/
	virtual void fuse_forget(fuse_ino_t ino, u_long nlookup) = 0;

	/************************************************************************************
	* FUSE-hook for fetching attributes of an INode
	***********************************************************************************/
	virtual int fuse_getattr(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) = 0;

	/************************************************************************************
	* FUSE-hook for open()ing an INode
	***********************************************************************************/
	virtual int fuse_open(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) = 0;

	/************************************************************************************
	* FUSE-hook for close()ing an INode
	***********************************************************************************/
	virtual int fuse_release(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) = 0;

	/************************************************************************************
	* FUSE-hook for read()ing from an open INode
	***********************************************************************************/
	virtual int fuse_read(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, fuse_file_info *fi) = 0;

	/************************************************************************************
	 * Is filesystem running in debug-mode?
	 ***********************************************************************************/
	bool debug;
private:
	/************************************************************************************
		* Read one instruction on Fuse Socket, and dispatch to handler.
		* Might block on read, you may want to check with a Selector first.
		***********************************************************************************/
	void dispatch_waiting(const boost::system::error_code& err, size_t count);

	void readNext();
private:
	boost::asio::posix::stream_descriptor _channel;
	std::string _mountpoint;
	fuse_chan * _fuse_chan;
	fuse_session * _fuse_session;
	Buffer _receive_buf;
};

#endif // FUSEPP_H
