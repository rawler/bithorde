
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
	std::string optMyName;
	bool optQuiet;
	std::string optConnectUrl;

	// Internal items
	boost::asio::io_service _ioSvc;
	boost::signals::connection _writeConnection;
	std::list<boost::filesystem::path> _files;
	bithorde::Client::Pointer _client;
	bithorde::UploadAsset * _currentAsset;
	std::ifstream _currentFile;
	uint64_t _currentOffset;
	Buffer _readBuf;
public:
	BHUpload(boost::program_options::variables_map &map);
	bool queueFile(const std::string& path);

	int main(const std::vector<std::string>& args);
private:
	void onAuthenticated(std::string& peerName);
	void onStatusUpdate(const bithorde::AssetStatus&);
	void onWritable();

	ssize_t readNext();
	bool tryWrite();

	void nextAsset();
};

#endif

