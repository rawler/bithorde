#ifndef QFILESYSTEM_H
#define QFILESYSTEM_H

#include <string>
#include <vector>

#include <boost/asio.hpp>

#define FUSE_USE_VERSION 26
#include <fuse_lowlevel.h>

#include <lib/types.h>

class BoostAsioFilesystem
{
	/****************************************************************************************
	* Abstract C++ class used to implement real FileSystems in a boost asynchronous manner.
	* Filesystem-implementations should extend this class, and implement each abstracted
	* method.
	***************************************************************************************/
public:
	BoostAsioFilesystem(boost::asio::io_service& ioSvc, std::string& mountpoint, std::vector<std::string>& args);
	~BoostAsioFilesystem();

	/************************************************************************************
	* FUSE-hook for mapping a name in a directory to an inode.
	***********************************************************************************/
	virtual int fuse_lookup(fuse_req_t req, fuse_ino_t parent, const char *name) = 0;

	/************************************************************************************
	* FUSE-hook informing that an INode may be forgotten
	***********************************************************************************/
	virtual void fuse_forget(fuse_ino_t ino, ulong nlookup) = 0;

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

#endif // QFILESYSTEM_H
