
#include "bhupload.h"

#include <iostream>
#include <list>
#include <sstream>
#include <utility>

#include <Poco/Delegate.h>
#include <Poco/Net/DNS.h>
#include <Poco/Util/HelpFormatter.h>

using namespace std;
using namespace Poco;
using namespace Poco::Net;
using namespace Poco::Util;

const static size_t BLOCK_SIZE = (64*1024);

BHUpload::BHUpload() :
	optHelp(false),
	optMyName("bhupload"),
	optQuiet(false),
	optHost("localhost"),
	optPort(1337),
	_currentAsset(NULL)
{}

void BHUpload::defineOptions(OptionSet & options) {
	options.addOption(Option("help", "h")
		.description("Show help")
	);
	options.addOption(Option("name", "n")
		.description("Bithorde-name of this client")
		.argument("name")
	);
	options.addOption(Option("quiet", "q")
		.description("Don't show progressbar")
	);
	options.addOption(Option("url", "u")
		.description("Where to connect to bithorde. Either host:port, or /path/socket")
		.argument("url")
	);
}

void BHUpload::handleOption(const std::string & name, const std::string & value) {
	if (name == "help") {
		optHelp = true;
	} else if (name == "name") {
		optMyName = value;
	} else if (name == "quiet") {
		optQuiet = true;
	} else if (name == "url") {
		std::size_t sepPos = value.rfind(':');
		if (sepPos == value.length()) {
			optHost = value;
		} else {
			optHost = value.substr(0, sepPos);
			istringstream iss(value.substr(sepPos+1));
			iss >> optPort;
		}
	}
}

int BHUpload::exitHelp() {
	HelpFormatter helpFormatter(options());
	helpFormatter.setCommand(commandName());
	helpFormatter.setUsage("OPTIONS <filePath> ...");
	helpFormatter.setHeader(
		"Simple BitHorde uploader, sending one or more concatenated assets and "
		"logging the resulting magnet-link on stdout."
	);
	helpFormatter.format(std::cerr);
	return EXIT_USAGE;
}

int BHUpload::main(const std::vector<std::string>& args) {
	if (args.empty() || optHelp)
		return exitHelp();
	std::vector<std::string>::const_iterator iter;
	for (iter = args.begin(); iter != args.end(); iter++) {
		if (!queueFile(*iter))
			return exitHelp();
	}

	SocketAddress addr(DNS::resolveOne("localhost"), 1338);
	StreamSocket sock;
	sock.connect(addr);
	Connection * c = new Connection(sock, _reactor);
	_client = new Client(*c, optMyName);
	_client->authenticated += delegate(this, &BHUpload::onAuthenticated);

	_reactor.run();

	return EXIT_OK;
}

bool BHUpload::queueFile(const std::string& path) {
	File file(path);
	if (!file.exists()) {
		logger().error("Non-existing file '" + path + "'");
		return false;
	}
	if (!(file.isFile() || file.isLink())) {
		logger().error("Path is not regular file '" + path + "'");
		return false;
	}
	if (!file.canRead()) {
		logger().error("File is not readable '" + path + "'");
		return false;
	}

	_files.push_back(file);
	return true;
}

void BHUpload::nextAsset() {
	if (_currentAsset) {
		_currentAsset->close();
		delete _currentAsset;
		_currentAsset = NULL;
	}
	if (_currentFile.is_open())
		_currentFile.close();

	if (_files.empty()) {
		_reactor.stop();
	} else {
		_currentFile.open(_files.front().path(), ifstream::in | ifstream::binary);
		_currentAsset = new UploadAsset(_client, _files.front().getSize());
		_currentAsset->statusUpdate += delegate(this, &BHUpload::onStatusUpdate);
		_client->bind(*_currentAsset);

		_currentOffset = 0;
		_files.pop_front();
	}
}

void BHUpload::onStatusUpdate(const bithorde::AssetStatus& status)
{
	switch (status.status()) {
	case bithorde::SUCCESS:
		if (status.ids_size()) {
			cout << MagnetURI(status) << endl;
			nextAsset();
		} else {
			logger().notice("Uploading ...");
			_client->writable += delegate(this, &BHUpload::onWritable);
			onWritable(NO_ARGS);
		}
		break;
	default:
		logger().error("Failed ...");
		break;
	}
}

void BHUpload::onWritable(Poco::EventArgs&)
{
	while (tryWrite());
}

bool BHUpload::tryWrite() {
	byte buf[BLOCK_SIZE];
	_currentFile.read((char*)buf, BLOCK_SIZE);
	size_t read = _currentFile.gcount();
	if (read > 0) {
		if (_currentAsset->tryWrite(_currentOffset, buf, read)) {
			_currentOffset += read;
			return true;
		} else {
			return false;
		}
	} else {
		// File reading done. Don't try to write before next is ready for upload.
		_client->writable -= delegate(this, &BHUpload::onWritable);
		return false;
	}
}

void BHUpload::onAuthenticated(string& peerName) {
	logger().notice("Connected to "+peerName);
	nextAsset();
}

int main(int argc, char *argv[]) {
	BHUpload app;
	app.init(argc, argv);

	int res = app.run();
	cerr.flush();
	return res;
}
