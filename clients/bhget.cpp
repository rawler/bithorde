
#include "bhget.h"

#include <iostream>
#include <list>
#include <sstream>
#include <utility>

#include <lib/buffer.hpp>

#include "buildconf.hpp"

namespace asio = boost::asio;
namespace po = boost::program_options;
using namespace std;

using namespace bithorde;

const static size_t BLOCK_SIZE = (64*1024);
const static size_t PARALLELL_BLOCKS = (4);
const static size_t BLOCK_RETRIES = 5;

struct OutQueue {
	typedef pair<uint64_t, string> Chunk;
	uint64_t position;
	list<Chunk> _stored;

	OutQueue() :
		position(0)
	{}

	void send(uint64_t offset, const string& data) {
		if (offset <= position) {
			BOOST_ASSERT(offset == position);
			_flush(data);
			_dequeue();
		} else {
			_queue(offset, data);
		}
	}

private:
	void _queue(uint64_t offset, const string& data) {
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

	void _flush(const string& data) {
		ssize_t datasize = data.size();
		if (write(1, data.data(), datasize) == datasize)
			position += datasize;
		else
			(cerr << "ERROR: failed to write block" << endl).flush();
	}
};

BHGet::BHGet(po::variables_map& args) :
	optMyName(args["name"].as<string>()),
	optQuiet(args.count("quiet")),
	optConnectUrl(args["url"].as<string>()),
	_res(0),
	optDebug(false)
{}

int BHGet::main(const std::vector<std::string>& args) {
	_res = 0;
	std::vector<std::string>::const_iterator iter;
	for (iter = args.begin(); iter != args.end(); iter++) {
		if (!queueAsset(*iter))
			return 1;
	}

	_client = Client::create(_ioSvc, optMyName);
	_client->authenticated.connect(boost::bind(&BHGet::onAuthenticated, this, _1, _2));
	_client->connect(optConnectUrl);

	_ioSvc.run();

	return _res;
}

bool resolvePath(MagnetURI& uri, const std::string &path_) {
	char pathbuf[PATH_MAX];
	auto path__ = realpath(path_.c_str(), pathbuf);
	if (!path__) {
		return false;
	} else {
		boost::filesystem::path p(path__);
		return uri.parse(p.filename().string());
	}
}

bool BHGet::queueAsset(const std::string& _uri) {
	MagnetURI uri;
	if (!uri.parse(_uri) && !resolvePath(uri, _uri)) {
		cerr << "ERROR: Only magnet-links and symlinks to magnet-links supported, not '" << _uri << "'" << endl;
		return false;
	}

	if (uri.xtIds.size()) {
		_assets.push_back(uri);
		return true;
	} else {
		cerr << "ERROR: No hash-Identifiers in '" << _uri << "'" << endl;
		return false;
	}
}

void BHGet::nextAsset() {
	if (_asset) {
		_asset->statusUpdate.disconnect(boost::bind(&BHGet::onStatusUpdate, this, _1));
		_asset->dataArrived.disconnect(boost::bind(&BHGet::onDataChunk, this, _1, _2, _3));
		_asset->close();
		_asset.reset();
	}

	BitHordeIds ids;
	while ((!ids.size()) && (!_assets.empty())) {
		MagnetURI nextUri = _assets.front();
		_assets.pop_front();
		ids = nextUri.toIdList();
	}
	if (!ids.size()) {
		_ioSvc.stop();
		return;
	}

	_asset.reset(new ReadAsset(_client, ids));
	_asset->statusUpdate.connect(boost::bind(&BHGet::onStatusUpdate, this, _1));
	_asset->dataArrived.connect(boost::bind(&BHGet::onDataChunk, this, _1, _2, _3));
	_client->bind(*_asset);

	_outQueue = new OutQueue();
	_currentOffset = 0;
	_failures = 0;
}

void BHGet::onStatusUpdate(const bithorde::AssetStatus& status)
{
	switch (status.status()) {
	case bithorde::SUCCESS:
		if (status.size() > 0) {
			if (status.handle()) {
				if (optDebug)
					cerr << "DEBUG: Downloading ..." << endl;
				requestMore();
			} else {
				cerr << "WARNING: Broken response" << endl;
				nextAsset();
			}
		} else {
			cerr << "DEBUG: Zero-sized asset, skipping ..." << endl;
			nextAsset();
		}
		break;
	default:
		cerr << "ERROR: Failed (" << bithorde::Status_Name(status.status()) << ") ..." << endl;
		_res += 1;
		nextAsset();
		break;
	}
}

void BHGet::requestMore()
{
	while (_currentOffset < (_outQueue->position + (BLOCK_SIZE*PARALLELL_BLOCKS)) &&
		_currentOffset < _asset->size()) {
		_asset->aSyncRead(_currentOffset, BLOCK_SIZE);
		_currentOffset += BLOCK_SIZE;
	}
}

void BHGet::onDataChunk(uint64_t offset, const boost::shared_ptr<bithorde::IBuffer>& data, int tag)
{
	if ((data->size() < BLOCK_SIZE) && ((offset+data->size()) < _asset->size())) {
		cerr << "WARNING: got unexpectedly small data-block at offset " << offset << ", " << data->size() << " vs. " << BLOCK_SIZE << endl;
		if (++_failures < BLOCK_RETRIES) {
			cerr << "Retrying..." << endl;
			_asset->aSyncRead(offset, BLOCK_SIZE);
		} else {
			cerr << "Too many retries, failing asset";
			nextAsset();
			return;
		}
	}
	string buf(reinterpret_cast<char*>(**data), data->size());
	_outQueue->send(offset, buf);
	if (_outQueue->position < _asset->size()) {
		requestMore();
	} else {
		nextAsset();
	}
}

void BHGet::onAuthenticated(Client& c, const string& peerName) {
	if (peerName.empty()) {
		cerr << "Failed authentication" << endl;
		_ioSvc.stop();
	}
	if (optDebug)
		cerr << "DEBUG: Connected to " << peerName << endl;
	cerr.flush();
	nextAsset();
}

int main(int argc, char *argv[]) {
	po::options_description desc("Supported options");
	desc.add_options()
		("help,h",
			"Show help")
		("debug,d",
			"Activate debug-logging")
		("version,v",
			"Show version")
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

	if (vm.count("version"))
		return bithorde::exit_version();

	if (vm.count("help") || !vm.count("magnet-url")) {
		cerr << desc << endl;
		return 1;
	}

	int res = -1;
	try {
		BHGet app(vm);
		app.optDebug = vm.count("debug");
		res = app.main(vm["magnet-url"].as< vector<string> >());
	} catch (std::string err) {
		cerr << err << endl;
	}
	cerr.flush();
	return res;
}
