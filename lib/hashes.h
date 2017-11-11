#ifndef BITHORDE_HASHES_H
#define BITHORDE_HASHES_H

#include <ostream>

#include <boost/filesystem/path.hpp>
#include <boost/log/utility/formatting_ostream.hpp>

#include <crypto++/files.h>
#include <crypto++/basecode.h>

#include "bithorde.pb.h"

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

std::string base32encode(const std::string& s);

namespace bithorde {

class Id {
	std::string _raw;
public:
	const static Id EMPTY;

	Id() {}

	static Id fromRaw(const std::string& raw) {
		Id res;
		res._raw = raw;
		return res;
	}

	static Id fromBase32(const std::string& base32) {
		Id res;
		CryptoPP::StringSource(base32, true,
			new RFC4648Base32Decoder(
				new CryptoPP::StringSink(res._raw)));
		return res;
	}

	std::string base32() const { return base32encode(_raw); }
	void writeBase32(std::ostream& str) const;
	const std::string& raw() const { return _raw; }

	bool empty() const { return _raw.empty(); }
	bool operator==(const Id &other) const {
		return other._raw == _raw;
	}
	bool operator!=(const Id &other) const {
		return other._raw != _raw;
	}
};
boost::filesystem::path operator/(const boost::filesystem::path& lhs, const Id& rhs);

typedef google::protobuf::RepeatedPtrField< bithorde::Identifier > Ids;

std::ostream& operator<<(std::ostream& str, const Id& id);

std::ostream& operator<<(std::ostream& str, const Ids& ids);
std::string idsToString(const Ids& ids);


Id findBithordeId(const Ids& ids, bithorde::HashType type);
}

namespace std
{
	template <>
	struct hash<bithorde::Id>
	{
		std::size_t operator()(const bithorde::Id& c) const
		{
			return std::hash<std::string>()(c.raw());
		}
	};
}



#endif // BITHORDE_HASHES_H
