#ifndef MAIN_H
#define MAIN_H

#include <QtCore/QObject>
#include <QtCore/QMap>

#include <allocator.h>
#include <libqhorde.h>

#include "qfilesystem.h"
#include "inode.h"
#include "lookup.h"

class BHFuse : public QFileSystem {
    Q_OBJECT
public:
    BHFuse(QString mountPoint, QVector<QString> args, QObject * parent=NULL);

    virtual int fuse_lookup(fuse_req_t req, fuse_ino_t parent, const char *name);
    virtual int fuse_forget(fuse_ino_t ino, ulong nlookup);
    virtual int fuse_getattr(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi);
    virtual int fuse_open(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi);
    virtual int fuse_release(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi);
    virtual int fuse_read(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, fuse_file_info *fi);

public slots:
    void onConnected(QString remoteName);
    FUSEAsset * registerAsset(ReadAsset * asset);

private:
    Client * client;

    QMap<fuse_ino_t, INode *> inode_cache;
    CachedAllocator<fuse_ino_t> ino_allocator;
};

#endif // MAIN_H
