
#include <vector>
#include <ctime>
#include <crypto++/tiger.h>
#include <boost/filesystem.hpp>
#include <boost/make_shared.hpp>
#include <boost/test/unit_test.hpp>

#include <bithorded/cache/asset.hpp>
#include <bithorded/lib/grandcentraldispatch.hpp>
#include <bithorded/store/asset.hpp>
#include <bithorded/store/hashstore.hpp>
#include <bithorded/source/store.hpp>

using namespace std;

namespace bsys = boost::system;
namespace fs = boost::filesystem;

using namespace bithorded;

struct TestData {
	boost::asio::io_service ioSvc;
	GrandCentralDispatch gcd;
	fs::path testData;
	TestData() :
		gcd(ioSvc, 4),
		testData(fs::path(__FILE__).parent_path() / "data")
	{}
};

/************** V1 assets **************/

BOOST_FIXTURE_TEST_CASE( open_partial_v1_asset, TestData )
{
	auto asset = cache::CachedAsset::open(gcd, testData/"v1"/".bh_meta"/"assets"/"cached_partial");
	BOOST_CHECK_EQUAL(asset->hasRootHash(), false);
	BOOST_CHECK_EQUAL(asset->can_read(asset->size()-1024, 1024), 0);
}

BOOST_FIXTURE_TEST_CASE( open_fully_cached_v1_asset, TestData )
{
	auto asset = cache::CachedAsset::open(gcd, testData/"v1"/".bh_meta"/"assets"/"cached");
	BOOST_CHECK_EQUAL(asset->hasRootHash(), true);
	BOOST_CHECK_EQUAL(asset->can_read(asset->size()-1024, 1024), 1024);
}

BOOST_FIXTURE_TEST_CASE( open_v1_linked_asset, TestData )
{
	source::Store repo(gcd, "test", testData/"v1");
	fs::path test_asset = testData/"v1"/".bh_meta"/"assets"/"linked";
	fs::path link_target = fs::absolute(fs::read_symlink(test_asset/"data"), test_asset);

	fs::remove(link_target);
	// Missing asset-data should fail
	BOOST_CHECK_THROW( repo.openAsset(test_asset), bsys::system_error );

	{
		// Create target_file
		RandomAccessFile f(link_target, RandomAccessFile::READWRITE, 130*1024);
		f.close();
	}
	fs::last_write_time(test_asset, std::time(NULL)-10000);
	// Should fail due to data newer than link
	BOOST_CHECK_EQUAL( repo.openAsset(test_asset), IAsset::Ptr() );

	fs::last_write_time(test_asset, std::time(NULL)+10000);

	auto asset = repo.openAsset(test_asset); // Should now succeed with newer link than data
	BOOST_CHECK_EQUAL(asset->can_read(0, 1024), 1024);
	BOOST_CHECK_EQUAL(asset->can_read(asset->size()-1024, 1024), 1024);
}


/************** V2 assets **************/

BOOST_FIXTURE_TEST_CASE( open_partial_v2_asset, TestData )
{
// 	auto asset = cache::CachedAsset::open(gcd, assetDir/"v2"/"cached_partial");
// 	BOOST_CHECK_EQUAL(asset->hasRootHash(), false);
}

BOOST_FIXTURE_TEST_CASE( open_fully_cached_v2_asset, TestData )
{
// 	auto asset = cache::CachedAsset::open(gcd, assetDir/"v2"/"cached");
// 	BOOST_CHECK_EQUAL(asset->hasRootHash(), true);
}

BOOST_FIXTURE_TEST_CASE( open_v2_linked_asset, TestData )
{
// 	fs::path test_asset = assetDir/"v2"/"linked";
// 	fs::path link_target; /* How the FUCK do I figure out this?! */
//
// 	fs::remove(link_target);
// 	// Missing asset-data should fail
// 	BOOST_CHECK_EXCEPTION( source::SourceAsset::open(gcd, test_asset), source::AssetError, link_is_gone );
//
// 	{
// 		// Create target_file
// 		RandomAccessFile f(link_target, RandomAccessFile::READWRITE, 130*1024);
// 		f.close();
// 	}
// 	fs::last_write_time(test_asset, std::time(NULL)-10000);
// 	// Should fail due to data newer than link
// 	BOOST_CHECK_EXCEPTION( source::SourceAsset::open(gcd, test_asset), source::AssetError, link_is_outdated );
//
// 	fs::last_write_time(test_asset, std::time(NULL)+10000);
//
// 	auto asset = source::SourceAsset::open(gcd, test_asset); // Should now succeed with newer link than data
// 	BOOST_CHECK_EQUAL(asset->hasRootHash(), true);
}
