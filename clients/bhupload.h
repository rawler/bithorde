
#ifndef BHUPLOAD_H
#define BHUPLOAD_H

#include <list>
#include <string>
#include <fstream>

#include <Poco/File.h>
#include <Poco/Foundation.h>
#include <Poco/Util/Application.h>

#include "lib/bithorde.h"

class BHUpload : public Poco::Util::Application {
	// Options
	bool optHelp;
	std::string optMyName;
	bool optQuiet;
	std::string optHost;
	uint16_t optPort;

	// Internal items
	Poco::Net::SocketReactor _reactor;
	std::list<Poco::File> _files;
	Client * _client;
	UploadAsset * _currentAsset;
	std::ifstream _currentFile;
	uint64_t _currentOffset;
public:
	BHUpload();
	bool queueFile(const std::string& path);

	virtual void defineOptions(Poco::Util::OptionSet & options);
	virtual void handleOption(const std::string & name, const std::string & value);
	int exitHelp();

	int main(const std::vector<std::string>& args);
private:
	void onAuthenticated(std::string& peerName);
	void onStatusUpdate(const bithorde::AssetStatus&);
	void onWritable(Poco::EventArgs&);
	bool tryWrite();

	void nextAsset();
};

#endif

