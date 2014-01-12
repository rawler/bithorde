#include <vector>

#include <crypto++/tiger.h>
#include <boost/filesystem.hpp>
#include <boost/test/unit_test.hpp>

#include "bithorded/lib/treestore.hpp"
#include "bithorded/lib/hashtree.hpp"
#include "bithorded/store/assetmeta.hpp"

using namespace std;
namespace fs = boost::filesystem;

using namespace bithorded::store;

typedef HashNode< CryptoPP::Tiger > MyNode;
typedef HashTree< AssetMeta > TigerTree;

const fs::path TEST_FILE("/tmp/assetmeta_test");

BOOST_AUTO_TEST_CASE( assetmeta_random_sequence )
{
	if (fs::exists(TEST_FILE))
		fs::remove(TEST_FILE);
	
	const uint LEAVES = 7;

	{
		AssetMeta store(TEST_FILE, LEAVES);
		TigerTree tree(store, 0);

		const auto unit_size = TigerTree::Hasher::UNITSIZE;
		byte block[unit_size];
		bzero(block, sizeof(block));

		auto root = tree.getRoot();

		tree.setData(0*unit_size, block, sizeof(block));
		tree.setData(1*unit_size, block, sizeof(block));

		tree.setData(6*unit_size, block, sizeof(block));

		tree.setData(4*unit_size, block, sizeof(block));
		tree.setData(5*unit_size, block, sizeof(block));
		tree.setData(3*unit_size, block, sizeof(block));

		BOOST_CHECK_EQUAL( root->state, MyNode::State::EMPTY);

		tree.setData(2*unit_size, block, sizeof(block));

		BOOST_CHECK_EQUAL( root->state, MyNode::State::SET );
		BOOST_CHECK_EQUAL( root->base32Digest(), "FPSZ35773WS4WGBVXM255KWNETQZXMTEJGFMLTA" );
	}

	{
		AssetMeta store(TEST_FILE, LEAVES);
		TigerTree tree(store, 0);
		auto root = tree.getRoot();

		BOOST_CHECK_EQUAL( root->state, MyNode::State::SET );
		BOOST_CHECK_EQUAL( root->base32Digest(), "FPSZ35773WS4WGBVXM255KWNETQZXMTEJGFMLTA" );
	}
}

BOOST_AUTO_TEST_CASE( wild_index_jump )
{
	if (fs::exists(TEST_FILE))
		fs::remove(TEST_FILE);

	const uint LEAVES = 16*1024;

	AssetMeta store(TEST_FILE, LEAVES);

	auto first = store[0];
	first->state = 99;
	for (uint i = 1; i < LEAVES; i++) {
		auto current = store[i];
		current->state = 0;
	}
	BOOST_ASSERT(first->state == 99 );
}
