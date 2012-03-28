#ifndef HASHES_H
#define HASHES_H

#include <ostream>

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

std::ostream& operator<<(std::ostream& str, const BitHordeIds& ids);

#endif // HASHES_H
