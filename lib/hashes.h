#ifndef BITHORDE_HASHES_H
#define BITHORDE_HASHES_H

#include <ostream>

#include <boost/filesystem/path.hpp>
#include <boost/log/utility/formatting_ostream.hpp>

#include <crypto++/files.h>
#include <crypto++/basecode.h>

#include "bithorde.pb.h"

typedef google::protobuf::RepeatedPtrField< bithorde::Identifier > BitHordeIds;

//! Converts given data to base 32, the code is based on http://www.faqs.org/rfcs/rfc4648.html.
class RFC4648Base32Encoder : public CryptoPP::SimpleProxyFilter
{
public:
	RFC4648Base32Encoder(BufferedTransformation *attachment = NULL, bool uppercase = true, int outputGroupSize = 0, const std::string &separator = ":", const std::string &terminator = "")
		: SimpleProxyFilter(new CryptoPP::BaseN_Encoder(new CryptoPP::Grouper), attachment)
	{
		IsolatedInitialize(CryptoPP::MakeParameters
		                   (CryptoPP::Name::Uppercase(), uppercase)
		                   (CryptoPP::Name::GroupSize(), outputGroupSize)
		                   (CryptoPP::Name::Separator(), CryptoPP::ConstByteArrayParameter(separator))
		                   (CryptoPP::Name::Terminator(), CryptoPP::ConstByteArrayParameter(terminator)));
	}

	void IsolatedInitialize(const CryptoPP::NameValuePairs &parameters);
};

std::string base32encode(const std::string& s);

//! Decode base 32 data back to bytes, the code is based on http://www.faqs.org/rfcs/rfc4648.html.
class RFC4648Base32Decoder : public CryptoPP::BaseN_Decoder
{
public:
	RFC4648Base32Decoder(CryptoPP::BufferedTransformation *attachment = NULL)
		: BaseN_Decoder(GetDefaultDecodingLookupArray(), 5, attachment) {}

	void IsolatedInitialize(const CryptoPP::NameValuePairs &parameters);
private:
	static const int * CRYPTOPP_API GetDefaultDecodingLookupArray();
};

class BinId {
	std::string _raw;
public:
	const static BinId EMPTY;

	BinId() {}

	static BinId fromRaw(const std::string& raw) {
		BinId res;
		res._raw = raw;
		return res;
	}

	static BinId fromBase32(const std::string& base32) {
		BinId res;
		CryptoPP::StringSource(base32, true,
			new RFC4648Base32Decoder(
				new CryptoPP::StringSink(res._raw)));
		return res;
	}

	std::string base32() const { return base32encode(_raw); }
	void writeBase32(std::ostream& str) const;
	const std::string& raw() const { return _raw; }

	bool empty() const { return _raw.empty(); }
	bool operator==(const BinId &other) const {
		return other._raw == _raw;
	}
	bool operator!=(const BinId &other) const {
		return other._raw != _raw;
	}
};

std::ostream& operator<<(std::ostream& str, const BinId& id);

namespace std
{
	template <>
	struct hash<BinId>
	{
	    std::size_t operator()(const BinId& c) const
	    {
	        return std::hash<std::string>()(c.raw());
	    }
	};
}

std::ostream& operator<<(std::ostream& str, const BitHordeIds& ids);
std::string idsToString(const BitHordeIds& ids);

boost::filesystem::path operator/(const boost::filesystem::path& lhs, const BinId& rhs);

BinId findBithordeId(const BitHordeIds& ids, bithorde::HashType type);

#endif // BITHORDE_HASHES_H
