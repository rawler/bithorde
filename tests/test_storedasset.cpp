
#include <vector>
#include <ctime>
#include <crypto++/tiger.h>
#include <boost/filesystem.hpp>
#include <boost/test/unit_test.hpp>

#include <lib/buffer.hpp>
#include <bithorded/cache/asset.hpp>
#include <bithorded/lib/grandcentraldispatch.hpp>
#include <bithorded/store/asset.hpp>
#include <bithorded/store/hashstore.hpp>
#include <bithorded/source/store.hpp>

using namespace std;

namespace bsys = boost::system;
namespace fs = boost::filesystem;

// Hack required since fs::copy wasn't defined
#if BOOST_VERSION >= 105000
  namespace fs3 = boost::filesystem;
#else
  namespace fs3 = boost::filesystem3;
#endif

using namespace bithorded;

struct TestData {
	boost::asio::io_service ioSvc;
	GrandCentralDispatch gcd;
	fs::path assets;

	TestData() :
		gcd(ioSvc, 4),
		assets(fs::path(__FILE__).parent_path() / "data" / "assets")
	{
	}
};

/************** V1 assets **************/

BOOST_FIXTURE_TEST_CASE( open_partial_v1_asset, TestData )
{
	auto temp = fs::unique_path("bhtest-asset-%%%%-%%%%");
	auto srcDir = assets/".bh_meta"/"assets"/"v1_cached_partial";
	fs3::copy(srcDir, temp);
	fs3::copy(srcDir/"data", temp/"data");
	fs3::copy(srcDir/"meta", temp/"meta");
	auto asset = cache::CachedAsset::open(gcd, temp);
	BOOST_CHECK_EQUAL(asset->hasRootHash(), false);
	BOOST_CHECK_EQUAL(asset->canRead(asset->size()-1024, 1024), 0);

	boost::asio::io_service::work work(ioSvc);
	asset->write(0, std::make_shared<bithorde::MemoryBuffer>(asset->size()), std::bind(&boost::asio::io_service::stop, &ioSvc)); // Yikes I want C++11 lambdas
	ioSvc.run();
	BOOST_CHECK_EQUAL(asset->hasRootHash(), true);
	fs::remove_all(temp);
}

BOOST_FIXTURE_TEST_CASE( open_fully_cached_v1_asset, TestData )
{
	auto asset = cache::CachedAsset::open(gcd, assets/".bh_meta"/"assets"/"v1_cached");
	BOOST_CHECK_EQUAL(asset->hasRootHash(), true);
	BOOST_CHECK_EQUAL(asset->canRead(asset->size()-1024, 1024), 1024);
}

BOOST_FIXTURE_TEST_CASE( open_v1_linked_asset, TestData )
{
	source::Store repo(gcd, "test", assets);
	fs::path assets_folder = assets/".bh_meta"/"assets";
	fs::path test_asset = assets_folder / "v1_linked";
	fs::path link_target = fs::absolute(fs::read_symlink(test_asset/"data"), test_asset);

	fs::remove(link_target);
	// Missing asset-data should fail
	BOOST_CHECK_THROW( repo.openAsset(test_asset), bsys::system_error );

	{
		// Create target_file
		RandomAccessFile f(link_target, RandomAccessFile::READWRITE, 130*1024);
		f.close();
	}

	fs::last_write_time(test_asset, std::time(NULL)+10000);
	// Should now succeed with newer link than data
	auto asset = std::static_pointer_cast<bithorded::source::SourceAsset>(repo.openAsset(test_asset));
	BOOST_CHECK_EQUAL(asset->canRead(0, 1024), 1024);
	BOOST_CHECK_EQUAL(asset->canRead(asset->size()-1024, 1024), 1024);
	asset.reset();

	fs::last_write_time(test_asset, std::time(NULL)-10000);
	// Should fail due to data newer than link
	asset = std::static_pointer_cast<bithorded::source::SourceAsset>(repo.openAsset(test_asset));
	BOOST_CHECK_EQUAL( asset->status->status(), bithorde::Status::NONE );
	fs::remove_all(assets_folder/asset->id());
}


/************** V2 assets **************/

BOOST_FIXTURE_TEST_CASE( open_partial_v2_asset, TestData )
{
	auto asset = cache::CachedAsset::open(gcd, assets/".bh_meta"/"assets"/"v2_cached_partial");
	BOOST_CHECK_EQUAL(asset->hasRootHash(), false);
	BOOST_CHECK_EQUAL(asset->canRead(asset->size()-1024, 1024), 0);
}

BOOST_FIXTURE_TEST_CASE( open_fully_cached_v2_asset, TestData )
{
	auto asset = cache::CachedAsset::open(gcd, assets/".bh_meta"/"assets"/"v2_cached");
	BOOST_CHECK_EQUAL(asset->hasRootHash(), true);
	BOOST_CHECK_EQUAL(asset->canRead(asset->size()-1024, 1024), 1024);
}

BOOST_FIXTURE_TEST_CASE( open_v2_linked_asset, TestData )
{
	source::Store repo(gcd, "test", assets);
	fs::path assets_folder = assets/".bh_meta"/"assets";
	fs::path test_asset = assets_folder/"v2_linked";
	fs::path link_target = fs::absolute(assets/"link-data", test_asset);

	fs::remove(link_target);

	// Missing asset-data should fail
	BOOST_CHECK_THROW( repo.openAsset(test_asset), bsys::system_error );

	{
		// Create target_file
		RandomAccessFile f(link_target, RandomAccessFile::READWRITE, 130*1024);
		f.close();
	}
	fs::last_write_time(test_asset, std::time(NULL)+10000);
	// Should now succeed with newer link than data
	auto asset = std::static_pointer_cast<bithorded::source::SourceAsset>(repo.openAsset(test_asset));
	BOOST_CHECK_EQUAL(asset->canRead(0, 1024), 1024);
	BOOST_CHECK_EQUAL(asset->canRead(asset->size()-1024, 1024), 1024);

	fs::last_write_time(test_asset, std::time(NULL)-10000);
	// Should fail due to data newer than link
	asset = std::static_pointer_cast<bithorded::source::SourceAsset>(repo.openAsset(test_asset));
	BOOST_CHECK_EQUAL( asset->status->status(), bithorde::Status::NONE );
	fs::remove_all(assets_folder/asset->id());
}
