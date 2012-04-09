#ifndef LOOKUP_H
#define LOOKUP_H

#include <boost/shared_ptr.hpp>
#include <boost/signals2/connection.hpp>

#include <fuse_lowlevel.h>

#include <lib/bithorde.h>

typedef std::pair<fuse_ino_t, std::string> LookupParams;

class BHFuse;
class FUSEAsset;

class Lookup
{
	BHFuse * fs;
	fuse_req_t req;
	fuse_file_info * fi;   // Set if came from fuse_open()
	FUSEAsset * fuseAsset; // Set if came from fuse_open()
	LookupParams lookup_params;   // Set if came from fuse_lookup()
	boost::shared_ptr<bithorde::ReadAsset> asset;
	boost::signals2::scoped_connection statusConnection;
public:
    explicit Lookup(BHFuse * fs, fuse_req_t req, MagnetURI & uri, LookupParams& p);
    explicit Lookup(BHFuse * fs, FUSEAsset * asset, fuse_req_t req, fuse_file_info * fi);

    void perform(bithorde::Client::Pointer& c);

private:
    void onStatusUpdate(const bithorde::AssetStatus & msg);
};

#endif // LOOKUP_H
