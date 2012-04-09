
#include <boost/filesystem.hpp>
#include <boost/make_shared.hpp>
#include <boost/program_options.hpp>
#include <iostream>

#include <crypto++/files.h>

#include "lib/hashes.h"
#include "store/linkedassetstore.hpp"
#include "server/config.hpp"
#include "server/server.hpp"

using namespace std;
namespace asio = boost::asio;
namespace fs = boost::filesystem;
namespace po = boost::program_options;

using namespace bithorded;

void whenDone(boost::shared_ptr<LinkedAssetStore> assetStore, Asset::Ptr a) {
	if (a == NULL) {
		cerr << "Failed" << endl;
	} else {
		google::protobuf::RepeatedPtrField<bithorde::Identifier> ids;
		a->getIds(ids);

		cerr << ids << endl;

		Asset::Ptr sameAsset = assetStore->findAsset(ids);

		BOOST_ASSERT(sameAsset.get());
		ids.Clear();
		sameAsset->getIds(ids);
		cerr << ids << endl;
	}
}

int main(int argc, char* argv[]) {
	try {
		Config cfg(argc, argv);
		asio::io_service ioSvc;
		Server server(ioSvc, cfg);
		ioSvc.run();
		return 0;
	} catch (ArgumentError& e) {
		cerr << e.what() << endl;
		Config::print_usage(cerr);
		return -1;
	}
}
