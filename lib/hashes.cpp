#include "hashes.h"

// base32.cpp - written and placed in the public domain by Frank Palazzolo, based on hex.cpp by Wei Dai
// imported to bithorde from http://www.cryptopp.com/wiki/File:RFC4648-Base32.zip by Ulrik Mikaelsson

#include <sstream>
#include <crypto++/pch.h>
#include <crypto++/files.h>

#include "bithorde.pb.h"

static const byte s_vecUpper[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
static const byte s_vecLower[] = "abcdefghijklmnopqrstuvwxyz234567";

using namespace CryptoPP;
using namespace bithorde;

void RFC4648Base32Encoder::IsolatedInitialize(const NameValuePairs &parameters)
{
	bool uppercase = parameters.GetValueWithDefault(Name::Uppercase(), true);
	m_filter->Initialize(CombinedNameValuePairs(
		parameters,
		MakeParameters(Name::EncodingLookupArray(), uppercase ? &s_vecUpper[0] : &s_vecLower[0], false)(Name::Log2Base(), 5, true)));
}

std::string base32encode(const std::string& s)
{
	std::string res;
	CryptoPP::StringSource(s, true,
	new RFC4648Base32Encoder(
		new CryptoPP::StringSink(res)));
	return res;
}

void RFC4648Base32Decoder::IsolatedInitialize(const NameValuePairs &parameters)
{
	BaseN_Decoder::Initialize(CombinedNameValuePairs(
		parameters,
		MakeParameters(Name::DecodingLookupArray(), GetDefaultDecodingLookupArray(), false)(Name::Log2Base(), 5, true)));
}

const int *RFC4648Base32Decoder::GetDefaultDecodingLookupArray()
{
	static volatile bool s_initialized = false;
	static int s_array[256];

	if (!s_initialized)
	{
		InitializeDecodingLookupArray(s_array, s_vecUpper, 32, true);
		s_initialized = true;
	}
	return s_array;
}

void bithorde::Id::writeBase32(std::ostream& str) const {
	CryptoPP::StringSource(_raw, true,
		new RFC4648Base32Encoder(
			new CryptoPP::FileSink(str)
		)
	);
}

std::ostream& bithorde::operator<<(std::ostream& str, const bithorde::Id& id)
{
	id.writeBase32(str);
	return str;
}

std::ostream& bithorde::operator<<(std::ostream& str, const bithorde::Ids& ids)
{
	for (auto iter = ids.begin(); iter != ids.end(); iter++) {
		str << bithorde::HashType_Name(iter->type()) << "=";
		CryptoPP::StringSource(iter->id(), true,
			new RFC4648Base32Encoder(
				new CryptoPP::FileSink(str)
			)
		);
		str << ",";
	}
	return str;
}

std::string bithorde::idsToString(const bithorde::Ids& ids) {
	std::ostringstream o;
	o << ids;
	return o.str();
}

boost::filesystem::path bithorde::operator/(const boost::filesystem::path& lhs, const bithorde::Id& rhs)
{
	return lhs / rhs.base32();
}

const bithorde::Id bithorde::Id::EMPTY;

bithorde::Id bithorde::findBithordeId(const bithorde::Ids& ids, bithorde::HashType type) {
	for (auto iter=ids.begin(); iter != ids.end(); iter++) {
		if (iter->type() == type)
			return bithorde::Id::fromRaw(iter->id());
	}
	return bithorde::Id::fromRaw("");
}
