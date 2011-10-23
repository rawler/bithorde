#include "inode.h"

#include <errno.h>

#include <QtCore/QTextStream>

static QTextStream qOut(stdout);
static QTextStream qErr(stderr);

INode::INode(QObject *parent, fuse_ino_t ino) :
    QObject(parent),
    refCount(1),
    nr(ino)
{
}

void INode::takeRef() {
    refCount.fetchAndAddRelaxed(1);
}

bool INode::dropRefs(int count) {
    if (refCount.fetchAndAddRelaxed(-count) > count)
        return true;
    else
        return false;
}

bool INode::fuse_reply_lookup(fuse_req_t req) {
    fuse_entry_param e;
    bzero(&e, sizeof(e));
    fill_stat_t(e.attr);
    e.attr_timeout = 5;
    e.entry_timeout = 5;
    e.generation = 1;
    e.ino = nr;

    fuse_reply_entry(req, &e);
    return true;
}

bool INode::fuse_reply_stat(fuse_req_t req) {
    struct stat s;
    bzero(&s, sizeof(s));
    fill_stat_t(s);
    fuse_reply_attr(req, &s, 5);
    return true;
}

BHReadOperation::BHReadOperation() :
    req(NULL),
    off(-1),
    size(0)
{}

BHReadOperation::BHReadOperation(fuse_req_t req, off_t off, size_t size) :
    req(req),
    off(off),
    size(size)
{}

FUSEAsset::FUSEAsset(QObject *parent, fuse_ino_t ino, ReadAsset *_asset) :
    INode(parent, ino),
    asset(_asset)
{
    size = _asset->size();
    _asset->setParent(this);
    connect(_asset, SIGNAL(dataArrived(quint64,QByteArray,int)), SLOT(onDataArrived(quint64,QByteArray,int)));
}

void FUSEAsset::fill_stat_t(struct stat &s) {
    s.st_mode = S_IFREG | 0555;
    s.st_ino = nr;
    s.st_size = size;
    s.st_nlink = 1;
}

void FUSEAsset::read(fuse_req_t req, off_t off, size_t size)
{
    int tag = asset->aSyncRead(off, size);
    readOperations.insert(tag, BHReadOperation(req, off, size));
}

void FUSEAsset::onDataArrived(quint64 offset, QByteArray data, int tag) {
    BHReadOperation op = readOperations.take(tag);
    if (op.req) {
        if ((off_t)offset == op.off)
            fuse_reply_buf(op.req, data.data(), data.length());
        else
            fuse_reply_err(op.req, EIO);
    } else {
        (qErr << "ERROR: got response for unknown request").flush();
    }
}
