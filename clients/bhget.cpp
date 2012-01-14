
#include "bhget.h"

#include <iostream>
#include <list>
#include <utility>

#include <Poco/Delegate.h>
#include <Poco/Net/DNS.h>

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
	_myName("bhget"),
	_asset(NULL)
{}

void BHGet::defineOptions() {
}

int BHGet::main(const std::vector<std::string>& args) {
	if (args.empty())
		return EXIT_USAGE;
	std::vector<std::string>::const_iterator iter;
	for (iter = args.begin(); iter != args.end(); iter++) {
		if (!queueAsset(*iter))
			return EXIT_USAGE;
	}

	SocketAddress addr(DNS::resolveOne("localhost"), 1338);
	StreamSocket sock;
	sock.connect(addr);
	Connection * c = new Connection(sock, _reactor);
	_client = new Client(*c, _myName);
	_client->authenticated += delegate(this, &BHGet::onAuthenticated);

	_reactor.run();

	return EXIT_OK;
}

bool BHGet::queueAsset(const std::string& _uri) {
	MagnetURI uri;
	if (!uri.parse(_uri)) {
		cerr << "Only magnet-links supported, not '" << _uri << "'" << endl;
		return false;
	}

	bool found_id = false;

	std::vector<ExactIdentifier>::iterator iter;
	for (iter = uri.xtIds.begin(); iter != uri.xtIds.end(); iter++) {
		if (iter->type == "urn:tree:tiger") {
			found_id = true;
			break;
		}
	}

	if (found_id) {
		_assets.push_back(uri);
		return true;
	} else {
		cerr << "No hash-Identifier in '" << _uri << "'" << endl;
		return false;
	}
}

void BHGet::nextAsset() {
	if (_asset) {
		_asset->close();
		delete _asset;
		_asset = NULL;
	}

	ByteArray tigerId;
	while (tigerId.empty() && !_assets.empty()) {
		MagnetURI nextUri = _assets.front();
		_assets.pop_front();

		vector<ExactIdentifier>::iterator iter;
		for (iter=nextUri.xtIds.begin(); iter != nextUri.xtIds.end(); iter++) {
			if (iter->type == "urn:tree:tiger") {
				tigerId = ByteArray(iter->id.begin(), iter->id.end());
				break;
			}
		}
	}
	if (tigerId.empty())
		_reactor.stop();

	ReadAsset::IdList ids;
	ids.push_back(ReadAsset::Identifier(bithorde::TREE_TIGER, tigerId));
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
	cerr.flush();
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
		(cerr << "Error: got unexpectedly small data-block" << endl).flush();
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
