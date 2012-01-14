
#ifndef BHGET_H
#define BHGET_H

#include <list>
#include <string>

#include <Poco/Foundation.h>
#include <Poco/Util/Application.h>

#include "lib/bithorde.h"

struct OutQueue;

class BHGet : public Poco::Util::Application {
	std::string _myName;
	std::list<MagnetURI> _assets;
	Client * _client;
	Poco::Net::SocketReactor _reactor;
	ReadAsset * _asset;
	uint64_t _currentOffset;
	OutQueue * _outQueue;
public:
	BHGet();
	bool queueAsset(const std::string& uri);

	void defineOptions();

	int main(const std::vector<std::string>& args);
private:
	void onAuthenticated(std::string& peerName);
	void onStatusUpdate(const bithorde::AssetStatus&);
	void onDataChunk(const ReadAsset::Segment&);

	void nextAsset();
	void requestMore();
};

#endif

