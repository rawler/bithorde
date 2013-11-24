
#include <vector>
#include <ctime>
#include <crypto++/tiger.h>
#include <boost/filesystem.hpp>
#include <boost/make_shared.hpp>
#include <boost/test/unit_test.hpp>

#include <bithorded/cache/asset.hpp>
#include <bithorded/lib/grandcentraldispatch.hpp>
#include <bithorded/source/asset.hpp>

using namespace std;
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

BOOST_FIXTURE_TEST_CASE( open_partial_asset, TestData )
{
	auto asset = cache::CachedAsset::open(gcd, testData/"assets"/"cached_partial");
	BOOST_CHECK_EQUAL(asset->hasRootHash(), false);
}

BOOST_FIXTURE_TEST_CASE( open_fully_cached_asset, TestData )
{
	auto asset = cache::CachedAsset::open(gcd, testData/"assets"/"cached");
	BOOST_CHECK_EQUAL(asset->hasRootHash(), true);
}

bool link_is_gone( const source::AssetError& ex ) { return ex.cause == source::AssetError::GONE; }
bool link_is_outdated( const source::AssetError& ex ) { return ex.cause == source::AssetError::OUTDATED; }

BOOST_FIXTURE_TEST_CASE( open_linked_asset, TestData )
{
	fs::path test_asset = testData/"assets"/"linked";
	fs::path link_target = fs::absolute(fs::read_symlink(test_asset/"data"), test_asset);

	fs::remove(link_target);
	// Missing asset-data should fail
	BOOST_CHECK_EXCEPTION( source::SourceAsset::open(gcd, test_asset), source::AssetError, link_is_gone );

	{
		// Create target_file
		RandomAccessFile f(link_target, RandomAccessFile::READWRITE, 130*1024);
		f.close();
	}
	fs::last_write_time(test_asset, std::time(NULL)-10000);
	// Should fail due to data newer than link
	BOOST_CHECK_EXCEPTION( source::SourceAsset::open(gcd, test_asset), source::AssetError, link_is_outdated );

	fs::last_write_time(test_asset, std::time(NULL)+10000);

	auto asset = source::SourceAsset::open(gcd, test_asset); // Should now succeed with newer link than data
	BOOST_CHECK_EQUAL(asset->hasRootHash(), true);
}
