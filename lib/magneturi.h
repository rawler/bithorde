#ifndef BITHORDE_MAGNETURI_H
#define BITHORDE_MAGNETURI_H

#include <iostream>
#include <string>
#include <vector>

#include "hashes.h"
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
	MagnetURI(const bithorde::AssetStatus& s);
	MagnetURI(const bithorde::BindRead& r);
	bool parse(const std::string& uri);

	std::vector<ExactIdentifier> xtIds;
	uint64_t size;

	BitHordeIds toIdList();

	friend std::ostream & operator<<(std::ostream&, const MagnetURI&);
};
std::ostream& operator<<(std::ostream&,const MagnetURI&);

#endif // BITHORDE_MAGNETURI_H
