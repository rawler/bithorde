#include "main.h"
#include "inode.h"
#include "lookup.h"

#include <errno.h>
#include <boost/make_shared.hpp>

using namespace std;

using namespace bithorde;

Lookup::Lookup(BHFuse * fs, fuse_req_t req, MagnetURI & uri, LookupParams& p) :
	fs(fs),
	req(req),
	fi(0),
	lookup_params(p)
{
	ReadAsset::IdList ids = uri.toIdList();

	asset = boost::make_shared<ReadAsset>(fs->client, ids);
}

Lookup::Lookup(BHFuse *fs, boost::shared_ptr<FUSEAsset>& asset, fuse_req_t req, fuse_file_info *fi) :
	fs(fs),
	req(req),
	fi(fi),
	fuseAsset(asset),
	asset(asset->asset)
{}

void Lookup::perform(Client::Pointer& c)
{
	statusConnection = asset->statusUpdate.connect(Asset::StatusSignal::slot_type(&Lookup::onStatusUpdate, this, _1));
	c->bind(*asset);
}

void Lookup::onStatusUpdate(const bithorde::AssetStatus &msg)
{
	if (msg.status() == ::bithorde::SUCCESS) {
		if (fuseAsset) {
			fuseAsset->fuse_reply_open(req, fi);
		} else {
			FUSEAsset* f_asset = fs->registerAsset(asset, lookup_params);
			f_asset->fuse_reply_lookup(req);
		}
	} else {
		fuse_reply_err(req, ENOENT);
	}
	delete this;
}


