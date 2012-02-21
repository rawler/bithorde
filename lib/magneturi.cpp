#include "magneturi.h"

#include "hashes.h"

#include <sstream>
#include <boost/algorithm/string.hpp>

const static std::string MAGNET_PREFIX = "magnet:?";

using namespace std;

ExactIdentifier::ExactIdentifier()
{}

ExactIdentifier::ExactIdentifier(const bithorde::Identifier& id)
{
	switch (id.type()) {
		case bithorde::TREE_TIGER: type = "urn:tree:tiger"; break;
		case bithorde::SHA1:       type = "urn:sha1"; break;
		case bithorde::SHA256:     type = "urn:sha256"; break;
		default:                   type = "unknown"; break;
	}
	this->id = id.id();
}

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

std::string ExactIdentifier::base32id() const
{
	std::string res;
	CryptoPP::StringSource((const byte*)id.data(), id.size(), true,
		new RFC4648Base32Encoder(
			new CryptoPP::StringSink(res)));
	return res;
}

MagnetURI::MagnetURI()
{}

MagnetURI::MagnetURI(const bithorde::AssetStatus& s)
{
	size = s.size();

	for (int i = 0; i < s.ids_size(); i++)
		xtIds.push_back(ExactIdentifier(s.ids(i)));
}

bool MagnetURI::parse(const string& uri_)
{
	if (uri_.compare(0, MAGNET_PREFIX.size(), MAGNET_PREFIX))
		return false;
	string uri(uri_, MAGNET_PREFIX.length());

	size_t query_start = uri_.find('?');
	if (query_start == string::npos)
		return false;

	string query = uri_.substr(query_start+1);
	vector<string> attributes;
	boost::algorithm::split(attributes, query, boost::algorithm::is_any_of("&"), boost::algorithm::token_compress_on);
	for (vector<string>::iterator iter = attributes.begin(); iter != attributes.end(); iter++) {
		string option = *iter;
		size_t splitPos = option.find('=');
		if (splitPos == option.size()) // TODO: Error handling
			continue;
		string key = option.substr(0, splitPos);
		string value = option.substr(splitPos+1);
		if (key == "xl")
			istringstream(value) >> size;
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

std::ostream& operator<<(std::ostream& str,const MagnetURI& uri) {
	str << "magnet:?";

	vector<ExactIdentifier>::const_iterator iter;
	for (iter=uri.xtIds.begin(); iter != uri.xtIds.end(); iter++) {
		str << "xt=" << iter->type << ':' << iter->base32id() << '&';
	}

	if (uri.size)
		str << "xl=" << uri.size;

	return str;
}

