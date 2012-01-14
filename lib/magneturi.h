#ifndef MAGNETURI_H
#define MAGNETURI_H

#include <inttypes.h>
#include <string>
#include <vector>

#include "types.h"

struct ExactIdentifier {
    std::string type;
    std::string id;

    static ExactIdentifier fromUrlEnc(std::string enc);

    std::string base32id();
};

struct MagnetURI
{
    bool parse(const std::string& uri);

    std::vector<ExactIdentifier> xtIds;
    uint64_t size;
};

#endif // MAGNETURI_H
