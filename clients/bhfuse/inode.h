#ifndef INODE_H
#define INODE_H

#include <sys/stat.h>

#include <QtCore/QAtomicInt>
#include <QtCore/QMap>
#include <QtCore/QObject>

#include <fuse_lowlevel.h>

#include <asset.h>

class INode : public QObject {
    Q_OBJECT
public:
    QAtomicInt refCount;
    fuse_ino_t nr;
    quint64 size;

    explicit INode(QObject * parent, fuse_ino_t ino);
    void takeRef();

    /**
     * Returns true if there are still references left to this asset.
     */
    bool dropRefs(int count);

    bool fuse_reply_lookup(fuse_req_t req);
    bool fuse_reply_stat(fuse_req_t req);
protected:
    virtual void fill_stat_t(struct stat & s) = 0;
};

class BHReadOperation {
public:
    fuse_req_t req;
    off_t off;
    size_t size;

    BHReadOperation();
    BHReadOperation(fuse_req_t req, off_t off, size_t size);
};

class FUSEAsset : public INode {
    Q_OBJECT
public:
    explicit FUSEAsset(QObject * parent, fuse_ino_t ino, ReadAsset * asset);

    void read(fuse_req_t req, off_t off, size_t size);
protected:
    virtual void fill_stat_t(struct stat & s);
private slots:
    void onDataArrived(quint64 offset, QByteArray data, int tag);
private:
    ReadAsset * asset;
    QMap<off_t, BHReadOperation> readOperations;
};

#endif // INODE_H
