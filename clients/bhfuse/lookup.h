#ifndef LOOKUP_H
#define LOOKUP_H

#include <QObject>

#include <fuse_lowlevel.h>

#include <libqhorde.h>

class BHFuse;

class Lookup : public QObject
{
    Q_OBJECT

    BHFuse * fs;
    fuse_req_t req;
    MagnetURI uri;
    ReadAsset * asset;
public:
    explicit Lookup(BHFuse * fs, fuse_req_t req, MagnetURI & uri);

    void request(Client * c);

private slots:
    void onStatusUpdate(const bithorde::AssetStatus & msg);
};

#endif // LOOKUP_H
