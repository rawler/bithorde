
#ifndef BHUPLOAD_H
#define BHUPLOAD_H

#include <list>
#include <string>
#include <fstream>

#define BOOST_FILESYSTEM_VERSION 3

#include <boost/asio.hpp>
#include <boost/filesystem.hpp>
#include <boost/program_options.hpp>

#include "lib/bithorde.h"

class BHUpload {
	// Options
	std::string optConnectUrl;
	bool optLink;
	std::string optMyName;
	bool optQuiet;
	int optBindTimeoutMs;

	// Internal items
	boost::asio::io_context _ioCtx;
	boost::signals2::connection _writeConnection;
	std::list<boost::filesystem::path> _files;
	bithorde::Client::Pointer _client;
	bithorde::UploadAsset * _currentAsset;
	std::ifstream _currentFile;
	uint64_t _currentOffset;
	Buffer _readBuf;
	int _res;
public:
	BHUpload(boost::program_options::variables_map &map);
	bool queueFile(const std::string& path);

	bool optDebug;

	int main(const std::vector<std::string>& args);
private:
	void onStatusUpdate(const bithorde::AssetStatus&);
	void onWritable();
	void onDisconnected();

	ssize_t readNext();
	bool tryWrite();

	void nextAsset();
};

#endif
