#include "hashes.h"

static const byte myAlphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

CryptoPP::Base32Encoder * getBase32Encoder(std::string & target) {
    CryptoPP::Base32Encoder * encoder = new CryptoPP::Base32Encoder();
    encoder->Initialize(CryptoPP::MakeParameters(CryptoPP::Name::EncodingLookupArray(), (const byte *)myAlphabet, false));
    encoder->Attach(new CryptoPP::StringSink(target));
    return encoder;
}
