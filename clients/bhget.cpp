
#include "bhget.h"

#include <iostream>
#include <list>
#include <sstream>
#include <utility>

namespace asio = boost::asio;
namespace po = boost::program_options;
using namespace std;

using namespace bithorde;

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
			BOOST_ASSERT(offset == position);
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
				BOOST_ASSERT(first.first == position);
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

BHGet::BHGet(po::variables_map& args) :
	optMyName(args["name"].as<string>()),
	optQuiet(args.count("quiet")),
	optConnectUrl(args["url"].as<string>()),
	_ioSvc(),
	_asset(NULL)
{
}

int BHGet::main(const std::vector<std::string>& args) {
	std::vector<std::string>::const_iterator iter;
	for (iter = args.begin(); iter != args.end(); iter++) {
		if (!queueAsset(*iter))
			return 1;
	}

	_client = Client::create(_ioSvc, optMyName);
	_client->authenticated.connect(boost::bind(&BHGet::onAuthenticated, this, _1));
	_client->connect(optConnectUrl);

	_ioSvc.run();

	return 0;
}

bool BHGet::queueAsset(const std::string& _uri) {
	MagnetURI uri;
	if (!uri.parse(_uri)) {
		cerr << "Only magnet-links supported, not '" << _uri << "'" << endl;
		return false;
	}

	if (uri.xtIds.size()) {
		_assets.push_back(uri);
		return true;
	} else {
		cerr << "No hash-Identifiers in '" << _uri << "'" << endl;
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
	if (ids.empty()) {
		_ioSvc.stop();
		return;
	}

	_asset = new ReadAsset(_client, ids);
	_asset->statusUpdate.connect(boost::bind(&BHGet::onStatusUpdate, this, _1));
	_asset->dataArrived.connect(boost::bind(&BHGet::onDataChunk, this, _1, _2, _3));
	_client->bind(*_asset);

	_outQueue = new OutQueue();
	_currentOffset = 0;
}

void BHGet::onStatusUpdate(const bithorde::AssetStatus& status)
{
	switch (status.status()) {
	case bithorde::SUCCESS:
		if (status.size() > 0 ) {
			cerr << "Downloading ..." << endl;
			requestMore();
		} else {
			cerr << "Zero-sized asset, skipping ..." << endl;
			nextAsset();
		}
		break;
	default:
		cerr << "Failed ..." << endl;
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

void BHGet::onDataChunk(uint64_t offset, ByteArray& data, int tag)
{
	_outQueue->send(offset, data);
	if ((data.size() < BLOCK_SIZE) && ((offset+data.size()) < _asset->size())) {
		 cerr << "Error: got unexpectedly small data-block" << endl;
	}
	if (_outQueue->position < _asset->size()) {
		requestMore();
	} else {
		nextAsset();
	}
}

void BHGet::onAuthenticated(string& peerName) {
	cerr << "Connected to "+peerName << endl;
	cerr.flush();
	nextAsset();
}

int main(int argc, char *argv[]) {
	po::options_description desc("Supported options");
	desc.add_options()
		("help,h",
			"Show help")
		("name,n", po::value< string >()->default_value("bhget"),
			"Bithorde-name of this client")
		("quiet,q",
			"Don't show progressbar")
		("url,u", po::value< string >()->default_value("/tmp/bithorde"),
			"Where to connect to bithorde. Either host:port, or /path/socket")
		("magnet-url", po::value< vector<string> >(), "magnet url(s) to fetch")
	;
	po::positional_options_description p;
	p.add("magnet-url", -1);

	po::command_line_parser parser(argc, argv);
	parser.options(desc).positional(p);

	po::variables_map vm;
	po::store(parser.run(), vm);
	po::notify(vm);

	if (vm.count("help") || !vm.count("magnet-url")) {
		cerr << desc << endl;
		return 1;
	}

	BHGet app(vm);

	int res = app.main(vm["magnet-url"].as< vector<string> >());
	cerr.flush();
	return res;
}
