#include "main.h"

#include <signal.h>
#include <errno.h>

#include <QtCore/QCoreApplication>
#include <QtCore/QString>
#include <QtCore/QTextStream>
#include <QtCore/QVector>

static QTextStream qOut(stdout);
static QTextStream qErr(stderr);

static const QString UNIX_SOCK_PATH("/tmp/bithorde");

void sigint(int sig) {
    qErr << "Intercepted signal#" << sig << "\n";
    if (sig == SIGINT) {
        qErr << "Exiting...\n";
        QCoreApplication::exit(sig);
    }
    qErr.flush();
}

int main(int argc, char *argv[])
{
    QCoreApplication a(argc, argv);
    signal(SIGINT, &sigint);

    QVector<QString> args;
    args.append("-v");
    args.append("-d");

    BHFuse fs("/tmp/bhfuse", args);

    return a.exec();
}

BHFuse::BHFuse(QString mountPoint, QVector<QString> args, QObject *parent) :
    QFileSystem(mountPoint, args, parent),
    ino_allocator(2)
{
    QLocalSocket * sock = new QLocalSocket(this);
    LocalConnection * c = new LocalConnection(*sock);
    sock->connectToServer(UNIX_SOCK_PATH);
    client = new Client(*c, "bhfuse", this);
    connect(client, SIGNAL(authenticated(QString)), SLOT(onConnected(QString)));
}

void BHFuse::onConnected(QString remoteName) {
    (qOut << "Connected to " << remoteName << "\n").flush();
}

int BHFuse::fuse_lookup(fuse_req_t req, fuse_ino_t parent, const char *name) {
    if (parent != 1)
        return ENOENT;

    MagnetURI uri;
    if (uri.parse(name)) {
        Lookup * lookup = new Lookup(this, req, uri);
        lookup->request(client);
    } else {
        return ENOENT;
    }
    return 0;
}

int BHFuse::fuse_forget(fuse_ino_t ino, ulong nlookup) {
    return false;
}

int BHFuse::fuse_getattr(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) {
    if (ino == 1) {
        struct stat attr;
        bzero(&attr, sizeof(attr));
        attr.st_mode = S_IFDIR | 0444;
        attr.st_blksize = 32*1024;
        attr.st_ino = ino;
        attr.st_nlink = 2;
        fuse_reply_attr(req, &attr, 5);
    } else if (inode_cache.contains(ino)) {
        inode_cache[ino]->fuse_reply_stat(req);
    } else {
        return ENOENT;
    }
    return 0;
}

int BHFuse::fuse_open(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) {
    return false;
}

int BHFuse::fuse_release(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) {
    return false;
}

int BHFuse::fuse_read(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, fuse_file_info *fi) {
    return false;
}

FUSEAsset * BHFuse::registerAsset(ReadAsset *asset)
{
    fuse_ino_t ino = ino_allocator.allocate();
    FUSEAsset * a = new FUSEAsset(this, ino, asset);
    asset->setParent(a);
    inode_cache[ino] = a;
    return a;
}

