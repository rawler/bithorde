#include "main.h"
#include "lookup.h"

#include <errno.h>

Lookup::Lookup(BHFuse * fs, fuse_req_t req, MagnetURI & uri) :
    QObject(fs),
    fs(fs),
    req(req),
    uri(uri),
    asset(0)
{

}

void Lookup::request(Client * c)
{
    ReadAsset::IdList ids;
    foreach (ExactIdentifier id, uri.xtIds) {
        if (id.type == "urn:tree:tiger")
            ids.append(ReadAsset::Identifier(bithorde::TREE_TIGER, id.id));
    }

    asset = new ReadAsset(c, ids, this);
    connect(asset, SIGNAL(statusUpdate(bithorde::AssetStatus)), SLOT(onStatusUpdate(bithorde::AssetStatus)));
    c->bindRead(*asset);
}

void Lookup::onStatusUpdate(const bithorde::AssetStatus &msg)
{
    if (msg.status() == ::bithorde::SUCCESS) {
        FUSEAsset * a = fs->registerAsset(asset);
        a->fuse_reply_lookup(req);
    } else {
        fuse_reply_err(req, ENOENT);
    }
    delete this;
}


