#include "main.h"
#include "inode.h"
#include "lookup.h"

#include <errno.h>

Lookup::Lookup(BHFuse * fs, fuse_req_t req, MagnetURI & uri) :
    QObject(fs),
    fs(fs),
    req(req),
    fi(0),
    fuseAsset(0)
{
    ReadAsset::IdList ids;
    foreach (ExactIdentifier id, uri.xtIds) {
        if (id.type == "urn:tree:tiger")
            ids.append(ReadAsset::Identifier(bithorde::TREE_TIGER, id.id));
    }

    asset = new ReadAsset(fs->client, ids, this);
}

Lookup::Lookup(BHFuse *fs, FUSEAsset *asset, fuse_req_t req, fuse_file_info *fi) :
    QObject(fs),
    fs(fs),
    req(req),
    fi(fi),
    fuseAsset(asset),
    asset(asset->asset)
{}

void Lookup::perform(Client * c)
{
    connect(asset, SIGNAL(statusUpdate(bithorde::AssetStatus)), SLOT(onStatusUpdate(bithorde::AssetStatus)));
    c->bindRead(*asset);
}

void Lookup::onStatusUpdate(const bithorde::AssetStatus &msg)
{
    if (msg.status() == ::bithorde::SUCCESS) {
        if (fuseAsset) {
            fuseAsset->fuse_reply_open(req, fi);
        } else {
            fuseAsset = fs->registerAsset(asset);
            fuseAsset->fuse_reply_lookup(req);
        }
    } else {
        fuse_reply_err(req, ENOENT);
    }
    delete this;
}


