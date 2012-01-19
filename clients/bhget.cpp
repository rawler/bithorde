
#include "bhget.h"

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

struct OutQueue {
	typedef pair<uint64_t, ByteArray> Chunk;
	uint64_t position;
	list<Chunk> _stored;

	OutQueue() :
		position(0)
	{}

	void send(uint64_t offset, const ByteArray & data) {
		if (offset <= position) {
			poco_assert(offset == position);
			_flush(data);
			_dequeue();
		} else {
			_queue(offset, data);
		}
	}

private:
	void _queue(uint64_t offset, const ByteArray & data) {
		list<Chunk>::iterator pos = _stored.begin();
		while ((pos != _stored.end()) && (pos->first < offset))
			pos++;
		_stored.insert(pos, Chunk(offset, data));
	}

	void _dequeue() {
		while (_stored.size()) {
			Chunk& first = _stored.front();
			if (first.first > position) {
				break;
			} else {
				poco_assert(first.first == position);
				_flush(first.second);
				_stored.pop_front();
			}
		}
	}

	void _flush(const ByteArray & data) {
		ssize_t datasize = data.size();
		if (write(1, data.data(), datasize) == datasize)
			position += datasize;
		else
			(cerr << "Error: failed to write block" << endl).flush();
	}
};

BHGet::BHGet() :
	optHelp(false),
	optMyName("bhget"),
	optQuiet(false),
	optHost("localhost"),
	optPort(1337),
	_asset(NULL)
{}

void BHGet::defineOptions(OptionSet & options) {
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

void BHGet::handleOption(const std::string & name, const std::string & value) {
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

int BHGet::exitHelp() {
	HelpFormatter helpFormatter(options());
	helpFormatter.setCommand(commandName());
	helpFormatter.setUsage("OPTIONS <magnet-link1> ...");
	helpFormatter.setHeader(
		"Simple BitHorde asset-fetcher fetching one or more concatenated assets and "
		"streaming to stdout."
	);
	helpFormatter.format(std::cerr);
	return EXIT_USAGE;
}

int BHGet::main(const std::vector<std::string>& args) {
	if (args.empty() || optHelp)
		return exitHelp();
	std::vector<std::string>::const_iterator iter;
	for (iter = args.begin(); iter != args.end(); iter++) {
		if (!queueAsset(*iter))
			return exitHelp();
	}

	SocketAddress addr(DNS::resolveOne("localhost"), 1338);
	StreamSocket sock;
	sock.connect(addr);
	Connection * c = new Connection(sock, _reactor);
	_client = new Client(*c, optMyName);
	_client->authenticated += delegate(this, &BHGet::onAuthenticated);

	_reactor.run();

	return EXIT_OK;
}

bool BHGet::queueAsset(const std::string& _uri) {
	MagnetURI uri;
	if (!uri.parse(_uri)) {
		logger().error("Only magnet-links supported, not '" + _uri + "'");
		return false;
	}

	if (uri.xtIds.size()) {
		_assets.push_back(uri);
		return true;
	} else {
		logger().error("No hash-Identifiers in '" + _uri + "'");
		return false;
	}
}

void BHGet::nextAsset() {
	if (_asset) {
		_asset->close();
		delete _asset;
		_asset = NULL;
	}

	ReadAsset::IdList ids;
	while (ids.empty() && !_assets.empty()) {
		MagnetURI nextUri = _assets.front();
		_assets.pop_front();
		ids = nextUri.toIdList();
	}
	if (ids.empty())
		_reactor.stop();

	_asset = new ReadAsset(_client, ids);
	_asset->statusUpdate += delegate(this, &BHGet::onStatusUpdate);
	_asset->dataArrived += delegate(this, &BHGet::onDataChunk);
	_client->bindRead(*_asset);

	_outQueue = new OutQueue();
	_currentOffset = 0;
}

void BHGet::onStatusUpdate(const bithorde::AssetStatus& status)
{
	switch (status.status()) {
	case bithorde::SUCCESS:
		if (status.size() > 0 ) {
			logger().notice("Downloading ...");
			requestMore();
		} else {
			logger().warning("Zero-sized asset, skipping ...");
			nextAsset();
		}
		break;
	default:
		logger().error("Failed ...");
		nextAsset();
		break;
	}
}

void BHGet::requestMore()
{
	while (_currentOffset < (_outQueue->position + (BLOCK_SIZE*10)) &&
		_currentOffset < _asset->size()) {
		_asset->aSyncRead(_currentOffset, BLOCK_SIZE);
		_currentOffset += BLOCK_SIZE;
	}
}

void BHGet::onDataChunk(const ReadAsset::Segment& s)
{
	_outQueue->send(s.offset, s.data);
	if ((s.data.size() < BLOCK_SIZE) && ((s.offset+s.data.size()) < _asset->size())) {
		logger().error("Error: got unexpectedly small data-block");
	}
	if (_outQueue->position < _asset->size()) {
		requestMore();
	} else {
		nextAsset();
	}
}

void BHGet::onAuthenticated(string& peerName) {
	logger().notice("Connected to "+peerName);
	nextAsset();
}

int main(int argc, char *argv[]) {
	BHGet app;
	app.init(argc, argv);

	int res = app.run();
	cerr.flush();
	return res;
}
