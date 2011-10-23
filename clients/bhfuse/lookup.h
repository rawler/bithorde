#ifndef LOOKUP_H
#define LOOKUP_H

#include <QObject>

#include <fuse_lowlevel.h>

#include <libqhorde.h>

class BHFuse;
class FUSEAsset;

class Lookup : public QObject
{
    Q_OBJECT

    BHFuse * fs;
    fuse_req_t req;
    fuse_file_info * fi;   // Set if came from fuse_open()
    FUSEAsset * fuseAsset; // Set if came from fuse_open()
    ReadAsset * asset;
public:
    explicit Lookup(BHFuse * fs, fuse_req_t req, MagnetURI & uri);
    explicit Lookup(BHFuse * fs, FUSEAsset * asset, fuse_req_t req, fuse_file_info * fi);

    void perform(Client * c);

private slots:
    void onStatusUpdate(const bithorde::AssetStatus & msg);
};

#endif // LOOKUP_H
