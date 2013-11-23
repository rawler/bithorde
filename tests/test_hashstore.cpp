
#include <vector>
#include <crypto++/tiger.h>
#include <boost/filesystem.hpp>
#include <boost/make_shared.hpp>
#include <boost/test/unit_test.hpp>

#include <bithorded/lib/treestore.hpp>
#include <bithorded/lib/hashtree.hpp>
#include <bithorded/store/hashstore.hpp>

using namespace std;
namespace fs = boost::filesystem;

using namespace bithorded::store;

typedef HashTree< HashStore > TigerTree;

class TestArray : public bithorded::IDataArray {
	std::vector<byte> _storage;
public:
	TestArray(size_t size)
	{
		_storage.resize(size);
	}

	virtual ssize_t write ( uint64_t offset, const void* src, size_t size ) {
		std::copy(static_cast<const byte *>(src), static_cast<const byte *>(src)+size, _storage.begin()+offset);
		return size;
	}
	virtual uint64_t size() const {
		return _storage.size();
	}
	virtual ssize_t read ( uint64_t offset, size_t size, byte* buf ) const {
		auto start = _storage.begin();
		std::advance(start, offset);
		auto end(start);
		std::advance(end, size);

		std::copy(start, end, buf);
		return size;
	}
	virtual string describe() {
		ostringstream oss;
		oss << "(Vector of size: " << _storage.size() << ")";
		return oss.str();
	}
};

BOOST_AUTO_TEST_CASE( hashstore_exceptions )
{
	BOOST_CHECK_THROW( new HashStore(boost::make_shared<TestArray>(0)), ios_base::failure );
	BOOST_CHECK_THROW( new HashStore(boost::make_shared<TestArray>(1)), ios_base::failure );
}

BOOST_AUTO_TEST_CASE( assetmeta_random_sequence )
{
	const uint LEAVES = 7;

	auto array = boost::make_shared<TestArray>(treesize(LEAVES)*sizeof(TigerBaseNode));
	{
		HashStore store(array);
		TigerTree tree(store, 0);

		const auto unit_size = TigerTree::TreeHasher::UNITSIZE;
		byte block[unit_size];
		bzero(block, sizeof(block));

		auto root = tree.getRoot();

		BOOST_CHECK_EQUAL( root->state, TigerBaseNode::State::EMPTY);

		tree.setData(0*unit_size, block, sizeof(block));
		tree.setData(1*unit_size, block, sizeof(block));

		tree.setData(6*unit_size, block, sizeof(block));

		tree.setData(4*unit_size, block, sizeof(block));
		tree.setData(5*unit_size, block, sizeof(block));
		tree.setData(3*unit_size, block, sizeof(block));

		BOOST_CHECK_EQUAL( root->state, TigerBaseNode::State::EMPTY);

		tree.setData(2*unit_size, block, sizeof(block));

		BOOST_CHECK_EQUAL( root->state, TigerBaseNode::State::SET );
		BOOST_CHECK_EQUAL( root->base32Digest(), "FPSZ35773WS4WGBVXM255KWNETQZXMTEJGFMLTA" );
	}

	{
		HashStore store(array);
		TigerTree tree(store, 0);
		auto root = tree.getRoot();

		BOOST_CHECK_EQUAL( root->state, TigerBaseNode::State::SET );
		BOOST_CHECK_EQUAL( root->base32Digest(), "FPSZ35773WS4WGBVXM255KWNETQZXMTEJGFMLTA" );
	}
}

BOOST_AUTO_TEST_CASE( wild_index_jump )
{
	const uint LEAVES = 16*1024;

	auto array = boost::make_shared<TestArray>(treesize(LEAVES)*sizeof(TigerBaseNode));
	HashStore store(array);

	auto first = store[0];
	first->state = 99;
	for (uint i = 1; i < LEAVES; i++) {
		auto current = store[i];
		current->state = 0;
	}
	BOOST_CHECK_EQUAL( first->state, 99 );
}
