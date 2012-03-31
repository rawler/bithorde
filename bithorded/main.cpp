
#include <boost/filesystem.hpp>
#include <boost/make_shared.hpp>
#include <boost/program_options.hpp>
#include <iostream>

#include <crypto++/files.h>

#include "lib/hashes.h"
#include "store/linkedassetstore.hpp"
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
	po::options_description desc("Supported options");
	desc.add_options()
		("help,h",
			"Show help")
		("debug,d",
			"Enable debug-logging")
		("basedir,B", po::value< vector<fs::path> >(),
			"Base-dir of Asset-store (can be repeated)")
	;
	po::positional_options_description p;
	p.add("basedir", -1);

	po::command_line_parser parser(argc, argv);
	parser.options(desc).positional(p);

	po::variables_map vm;
	po::store(parser.run(), vm);
	po::notify(vm);

	if (vm.count("help") || !vm.count("basedir")) {
		cerr << desc << endl;
		return 1;
	}

	asio::io_service ioSvc;

	Server server(ioSvc, vm["basedir"].as< vector<fs::path> >());

	ioSvc.run();
}
