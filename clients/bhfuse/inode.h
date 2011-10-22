#ifndef INODE_H
#define INODE_H

#include <sys/stat.h>

#include <QObject>

#include <fuse_lowlevel.h>

#include <asset.h>

class INode : public QObject {
    Q_OBJECT
public:
    fuse_ino_t nr;
    quint64 size;

    explicit INode(QObject * parent, fuse_ino_t ino);

    bool fuse_reply_lookup(fuse_req_t req);
    bool fuse_reply_stat(fuse_req_t req);
protected:
    virtual void fill_stat_t(struct stat & s) = 0;
};

class FUSEAsset : public INode {
    Q_OBJECT
public:
    explicit FUSEAsset(QObject * parent, fuse_ino_t ino, ReadAsset * asset);
protected:
    virtual void fill_stat_t(struct stat & s);
private:
    ReadAsset * asset;
};

#endif // INODE_H
