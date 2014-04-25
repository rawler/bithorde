#include <algorithm>
#include <vector>

#include <crypto++/tiger.h>
#include <boost/test/unit_test.hpp>

#include "bithorded/lib/treestore.hpp"
#include "bithorded/lib/hashtree.hpp"

#include "test_storage.hpp"

using namespace std;

typedef HashNode< CryptoPP::Tiger > MyNode;
typedef TestStorage< MyNode > Storage;
typedef HashTree< Storage > TigerTree;

std::string tree_hasher(const std::string& input) {
	std::string res;
	typedef TreeHasher< CryptoPP::Tiger > Hasher;
	byte buf[Hasher::DigestSize];
	Hasher::rootDigest((const byte*)input.c_str(), input.length(), buf);
	CryptoPP::StringSource pipe(buf, Hasher::DigestSize, false,
		new RFC4648Base32Encoder(
			new CryptoPP::StringSink(res)));
	pipe.PumpAll();
	return res;
}

BOOST_AUTO_TEST_CASE( tree_hash_test )
{
	BOOST_CHECK_EQUAL( tree_hasher("A"), "F33GDTSNFCYLSQSR32XFIH3DIDBSBF4GRLU76VA" );
	BOOST_CHECK_EQUAL( tree_hasher(string(1024, 'A')), "L66Q4YVNAFWVS23X2HJIRA5ZJ7WXR3F26RSASFA" );
	BOOST_CHECK_EQUAL( tree_hasher(string(1025, 'A')), "PZMRYHGY6LTBEH63ZWAHDORHSYTLO4LEFUIKHWY" );
	BOOST_CHECK_EQUAL( tree_hasher(string(2048, 'A')), "FSINHKGFD6E3PHTXSA5EATMEO7IND3ATJDSH45A" );
	BOOST_CHECK_EQUAL( tree_hasher(string(2049, 'A')), "2IFFIJQ22FKZA3NCSVOQHPVJVNPJKTGDKOB3LTI" );
	BOOST_CHECK_EQUAL( tree_hasher(string(4000, 'A')), "5CF7JLZQNXHDANLGXZBBWMX6ZYVSDUD3C5SMOXI" );
	BOOST_CHECK_EQUAL( tree_hasher(string(5000, 'A')), "UUP5PDB4H3O6DWLTNGDC6RO27HK5IYSEFPE2LLI" );
	BOOST_CHECK_EQUAL( tree_hasher(string(87234, 'A')), "5V7AM5PT6PVGTCWITETZUFPBTCDK2DPHBJMTFWI" );
}

BOOST_AUTO_TEST_CASE( hashtree_random_sequence )
{
	const uint LEAVES = 7;
	Storage store(treesize(LEAVES));
	const size_t blockSize = 4096;
	TigerTree tree(store, 2);

	byte block[blockSize];
	bzero(block, sizeof(block));

	auto root = tree.getRoot();

	tree.setData(0*blockSize, block, sizeof(block));
	tree.setData(1*blockSize, block, sizeof(block));

	tree.setData(6*blockSize, block, sizeof(block));

	tree.setData(4*blockSize, block, sizeof(block));
	tree.setData(5*blockSize, block, sizeof(block));
	tree.setData(3*blockSize, block, sizeof(block));

	BOOST_CHECK_EQUAL( root->state, MyNode::State::EMPTY);

	tree.setData(2*blockSize, block, sizeof(block));

	BOOST_CHECK_EQUAL( root->state, MyNode::State::SET );
	BOOST_CHECK_EQUAL( root->base32Digest(), "J7BVBFH4WRRVYPDVCZTIGVFABQSIDUTEEQJQFNQ" );
}

string rootBase32(std::string input) {
	size_t blockSize = 4096;
	uint LEAVES = (input.size() + blockSize - 1) / blockSize;
	Storage store(treesize(LEAVES));
	TigerTree tree(store, 2);

	const byte* data = (const byte*) input.c_str();
	for (size_t i=0; i < input.size(); i += blockSize) {
		size_t bl = std::min(input.size() - i, blockSize);
		tree.setData(i, data+i, bl);
	}

	auto root = tree.getRoot();

	BOOST_CHECK_EQUAL( root->state, MyNode::State::SET );
	return root->base32Digest();
}

BOOST_AUTO_TEST_CASE( test_vectors )
{
	BOOST_CHECK_EQUAL( rootBase32("A"), "F33GDTSNFCYLSQSR32XFIH3DIDBSBF4GRLU76VA" );
	BOOST_CHECK_EQUAL( rootBase32(string(1024, 'A')), "L66Q4YVNAFWVS23X2HJIRA5ZJ7WXR3F26RSASFA" );
	BOOST_CHECK_EQUAL( rootBase32(string(1025, 'A')), "PZMRYHGY6LTBEH63ZWAHDORHSYTLO4LEFUIKHWY" );
	BOOST_CHECK_EQUAL( rootBase32(string(2048, 'A')), "FSINHKGFD6E3PHTXSA5EATMEO7IND3ATJDSH45A" );
	BOOST_CHECK_EQUAL( rootBase32(string(2049, 'A')), "2IFFIJQ22FKZA3NCSVOQHPVJVNPJKTGDKOB3LTI" );
	BOOST_CHECK_EQUAL( rootBase32(string(4000, 'A')), "5CF7JLZQNXHDANLGXZBBWMX6ZYVSDUD3C5SMOXI" );
	BOOST_CHECK_EQUAL( rootBase32(string(5000, 'A')), "UUP5PDB4H3O6DWLTNGDC6RO27HK5IYSEFPE2LLI" );
	BOOST_CHECK_EQUAL( rootBase32(string(87234, 'A')), "5V7AM5PT6PVGTCWITETZUFPBTCDK2DPHBJMTFWI" );
}
