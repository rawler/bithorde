#ifndef MAGNETURI_H
#define MAGNETURI_H

#include <inttypes.h>
#include <iostream>
#include <string>
#include <vector>

#include "asset.h"
#include "types.h"

struct ExactIdentifier {
	ExactIdentifier();
	ExactIdentifier(const bithorde::Identifier&);
	
	std::string type;
	std::string id;

	static ExactIdentifier fromUrlEnc(std::string enc);

	std::string base32id() const;
};

struct MagnetURI
{
	MagnetURI();
	MagnetURI(const bithorde::AssetStatus&);
	bool parse(const std::string& uri);

	std::vector<ExactIdentifier> xtIds;
	uint64_t size;

	ReadAsset::IdList toIdList();

	friend std::ostream & operator<<(std::ostream&, const MagnetURI&);
};
std::ostream& operator<<(std::ostream&,const MagnetURI&);

#endif // MAGNETURI_H
