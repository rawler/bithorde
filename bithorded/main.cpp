
#include <boost/filesystem.hpp>
#include <boost/make_shared.hpp>
#include <boost/program_options.hpp>
#include <iostream>

#include <crypto++/files.h>

#include "lib/hashes.h"
#include "store/linkedassetstore.hpp"

using namespace std;
namespace asio = boost::asio;
namespace fs = boost::filesystem;
namespace po = boost::program_options;

void whenDone(boost::shared_ptr<LinkedAssetStore> assetStore, boost::shared_ptr<Asset> a) {
	if (a == NULL) {
		cerr << "Failed" << endl;
	} else {
		google::protobuf::RepeatedPtrField<bithorde::Identifier> ids;
		a->getIds(ids);

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
		("basedir,B", po::value< fs::path >(),
			"Base-dir of Asset-store")
		("file,f", po::value< fs::path >(),
			"file")
	;
	po::positional_options_description p;
	p.add("basedir", 1);
	p.add("file", 1);

	po::command_line_parser parser(argc, argv);
	parser.options(desc).positional(p);

	po::variables_map vm;
	po::store(parser.run(), vm);
	po::notify(vm);

	if (vm.count("help") || !vm.count("file")) {
		cerr << desc << endl;
		return 1;
	}

	asio::io_service ioSvc;
	fs::path basedir = vm["basedir"].as< fs::path >();

	boost::shared_ptr<LinkedAssetStore> store = boost::make_shared<LinkedAssetStore>(ioSvc, basedir);
	fs::path file = vm["file"].as< fs::path >();

	store->addAsset(file, boost::bind(&whenDone, store, _1));

	ioSvc.run();
}
