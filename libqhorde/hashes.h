#ifndef HASHES_H
#define HASHES_H

#include <crypto++/base32.h>
#include <crypto++/filters.h>

CryptoPP::Base32Encoder * getBase32Encoder(std::string & target);

#endif // HASHES_H
