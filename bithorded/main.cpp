
#include <boost/filesystem.hpp>
#include <boost/program_options.hpp>
#include <iostream>

#include <crypto++/files.h>

#include "lib/hashes.h"
#include "store/asset.hpp"

using namespace std;
namespace fs = boost::filesystem;
namespace po = boost::program_options;

int main(int argc, char* argv[]) {
	po::options_description desc("Supported options");
	desc.add_options()
		("help,h",
			"Show help")
		("debug,d",
			"Enable debug-logging")
		("file,f", po::value< fs::path >(),
			"file")
	;
	po::positional_options_description p;
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

	fs::path file = vm["file"].as< fs::path >();
	fs::path metafile("/tmp/metafile");
	if (fs::exists(metafile))
		fs::remove(metafile);
	Asset a(file, metafile);

	uint64_t filesize = fs::file_size(file);
	a.notifyValidRange(0, filesize);

	byte rootDigest[Asset::Hasher::DigestSize];
	a.getRootHash(rootDigest);

	CryptoPP::StringSource(rootDigest, Asset::Hasher::DigestSize, true,
		new RFC4648Base32Encoder(
			new CryptoPP::FileSink(cout)
		)
	);

	cerr << endl;
}
