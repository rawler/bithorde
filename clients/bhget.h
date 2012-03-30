
#ifndef BHGET_H
#define BHGET_H

#include <list>
#include <string>

#include <boost/asio.hpp>
#include <boost/program_options.hpp>

#include "lib/bithorde.h"

struct OutQueue;

class BHGet {
	// Options
	std::string optMyName;
	bool optQuiet;
	std::string optConnectUrl;

	// Internal items
	std::list<MagnetURI> _assets;
	bithorde::Client::Pointer _client;
	boost::asio::io_service _ioSvc;
	bithorde::ReadAsset * _asset;
	uint64_t _currentOffset;
	OutQueue * _outQueue;
public:
	BHGet(boost::program_options::variables_map &map);
	bool queueAsset(const std::string& uri);

	int main(const std::vector<std::string>& args);
private:
	void onAuthenticated(std::string& peerName);
	void onStatusUpdate(const bithorde::AssetStatus&);
	void onDataChunk(uint64_t offset, ByteArray& data, int tag);

	void nextAsset();
	void requestMore();
};

#endif

