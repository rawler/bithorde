#include "qfilesystem.h"

#include <QtCore/QString>
#include <QtCore/QVector>

#include <errno.h>

#include <fuse_lowlevel.h>

extern "C" {
    // D-wrappers to map fuse_userdata to a specific FileSystem. Also ensures fuse gets
    // an error if an Exception aborts control.
    static void _op_lookup(fuse_req_t req, fuse_ino_t parent, const char *name) {
        int res = ((QFileSystem*)fuse_req_userdata(req))->fuse_lookup(req, parent, name);
        if (res)
            fuse_reply_err(req, res);
    }
    static void _op_forget(fuse_req_t req, fuse_ino_t ino, ulong nlookup) {
        ((QFileSystem*)fuse_req_userdata(req))->fuse_forget(req, ino, nlookup);
        fuse_reply_none(req);
    }
    static void _op_getattr(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) {
        int res = ((QFileSystem*)fuse_req_userdata(req))->fuse_getattr(req, ino, fi);
        if (res)
            fuse_reply_err(req, res);
    }
    static void _op_open(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) {
        int res = ((QFileSystem*)fuse_req_userdata(req))->fuse_open(req, ino, fi);
        if (res)
            fuse_reply_err(req, res);
    }
    static void _op_release(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) {
        int res = ((QFileSystem*)fuse_req_userdata(req))->fuse_release(req, ino, fi);
        if (res)
            fuse_reply_err(req, res);
    }
    static void _op_read(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, fuse_file_info *fi) {
        int res = ((QFileSystem*)fuse_req_userdata(req))->fuse_read(req, ino, size, off, fi);
        if (res)
            fuse_reply_err(req, res);
    }
}

QFileSystem::QFileSystem(QString mountpoint, QVector<QString> args, QObject * parent)
    : QObject(parent)
{
    _mountpoint = strdup(mountpoint.toUtf8().data());
    quint16 argc = args.count();
    char** argv = (char**)alloca(argc * sizeof(char*));
    for (int i=0; i < argc; i++)
        argv[i] = args[i].toUtf8().data();

    fuse_args f_args = FUSE_ARGS_INIT(argc, argv);

    _fuse_chan = fuse_mount(_mountpoint, &f_args);
    Q_ASSERT(_fuse_chan);
    // scope(failure) fuse_unmount(_mountpoint, _fuse_chan);

    _socketNotifier = new QSocketNotifier(fuse_chan_fd(_fuse_chan), QSocketNotifier::Read, this);
    connect(_socketNotifier, SIGNAL(activated(int)), SLOT(dispatch_waiting()));

    /************************************************************************************
     * FUSE_lowlevel_ops struct, pointing to the C++-class-wrappers.
     ***********************************************************************************/
    static fuse_lowlevel_ops qfs_ops;
    bzero(&qfs_ops, sizeof(qfs_ops));
    qfs_ops.lookup =  _op_lookup;
    qfs_ops.forget =  _op_forget;
    qfs_ops.getattr = _op_getattr;
    qfs_ops.open =    _op_open;
    qfs_ops.read =    _op_read;
    qfs_ops.release = _op_release;

    _fuse_session = fuse_lowlevel_new(&f_args, &qfs_ops, sizeof(qfs_ops), this);
    // scope(failure)fuse_session_destroy(s);

    fuse_session_add_chan(_fuse_session, _fuse_chan);
}

QFileSystem::~QFileSystem() {
    if (_fuse_chan)
        fuse_unmount(_mountpoint, _fuse_chan);
    if (_fuse_session)
        fuse_session_destroy(_fuse_session);
}

void QFileSystem::dispatch_waiting() {
    char buf[1024*128];
    int res = fuse_chan_recv(&_fuse_chan, buf, sizeof(buf));

    if (res>0) {
        fuse_session_process(_fuse_session, buf, res, _fuse_chan);
    }
}
