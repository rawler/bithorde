#include "magneturi.h"

#include "hashes.h"

#include <sstream>

#include <Poco/StringTokenizer.h>

const static std::string MAGNET_PREFIX = "magnet:?";

using namespace std;
using namespace Poco;

ExactIdentifier ExactIdentifier::fromUrlEnc(string enc)
{
	ExactIdentifier res;
	int lastColon = enc.find_last_of(':');
	res.type = enc.substr(0,lastColon);
	std::string assetid;
	CryptoPP::StringSource(enc.substr(lastColon+1), true,
		new RFC4648Base32Decoder(
			new CryptoPP::StringSink(assetid)));
	res.id = assetid;
	return res;
}

std::string ExactIdentifier::base32id()
{
	std::string res;
	CryptoPP::StringSource((const byte*)id.data(), id.size(), true,
		new RFC4648Base32Encoder(
			new CryptoPP::StringSink(res)));
	return res;
}

bool MagnetURI::parse(const string& uri_)
{
	if (uri_.compare(0, MAGNET_PREFIX.size(), MAGNET_PREFIX))
		return false;
	string uri(uri_, MAGNET_PREFIX.length());
	
	StringTokenizer tokenizer(uri, "&", StringTokenizer::TOK_IGNORE_EMPTY | StringTokenizer::TOK_TRIM);
	for (StringTokenizer::Iterator iter = tokenizer.begin(); iter != tokenizer.end(); iter++) {
		string option = *iter;
		size_t splitPos = option.find('=');
		if (splitPos == option.size()) // TODO: Error handling
			continue;
		string key = option.substr(0, splitPos);
		string value = option.substr(splitPos+1);
		if (key == "xl")
			stringstream(value) >> size;
		else if (key == "xt")
			xtIds.push_back(ExactIdentifier::fromUrlEnc(value));
	}
	return true;
}

ReadAsset::IdList MagnetURI::toIdList ()
{
	ReadAsset::IdList ids;

	vector<ExactIdentifier>::iterator iter;
	for (iter=xtIds.begin(); iter != xtIds.end(); iter++) {
		ByteArray hashId(iter->id.begin(), iter->id.end());
		if (iter->type == "urn:tree:tiger")
			ids.push_back(ReadAsset::Identifier(bithorde::TREE_TIGER, hashId));
	}

	return ids;
}
