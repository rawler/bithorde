#include "inode.h"

INode::INode(QObject *parent, fuse_ino_t ino) :
    QObject(parent),
    nr(ino)
{
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

FUSEAsset::FUSEAsset(QObject *parent, fuse_ino_t ino, ReadAsset *_asset) :
    INode(parent, ino),
    asset(_asset)
{
    size = _asset->size();
}

void FUSEAsset::fill_stat_t(struct stat &s) {
    s.st_mode = S_IFREG | 0555;
    s.st_ino = nr;
    s.st_size = size;
    s.st_nlink = 1;
}
