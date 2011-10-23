#ifndef QFILESYSTEM_H
#define QFILESYSTEM_H

#include <QObject>
#include <QtCore/QSocketNotifier>

#include <string.h>

#define FUSE_USE_VERSION 26
#include <fuse_lowlevel.h>

class QFileSystem : public QObject
{
    /****************************************************************************************
     * Abstract C++ class used to implement real FileSystems in a Qt asynchronous manner.
     * Filesystem-implementations should extend this class, and implement each abstracted
     * method.
     ***************************************************************************************/
Q_OBJECT

public:
    QFileSystem(QString mountpoint, QVector<QString> args, QObject * parent=0);
    ~QFileSystem();

    /************************************************************************************
     * FUSE-hook for mapping a name in a directory to an inode.
     ***********************************************************************************/
    virtual int fuse_lookup(fuse_req_t req, fuse_ino_t parent, const char *name) = 0;

    /************************************************************************************
     * FUSE-hook informing that an INode may be forgotten
     ***********************************************************************************/
    virtual void fuse_forget(fuse_ino_t ino, ulong nlookup) = 0;

    /************************************************************************************
     * FUSE-hook for fetching attributes of an INode
     ***********************************************************************************/
    virtual int fuse_getattr(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) = 0;

    /************************************************************************************
     * FUSE-hook for open()ing an INode
     ***********************************************************************************/
    virtual int fuse_open(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) = 0;

    /************************************************************************************
     * FUSE-hook for close()ing an INode
     ***********************************************************************************/
    virtual int fuse_release(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) = 0;

    /************************************************************************************
     * FUSE-hook for read()ing from an open INode
     ***********************************************************************************/
    virtual int fuse_read(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, fuse_file_info *fi) = 0;

private slots:
    /************************************************************************************
     * Read one instruction on Fuse Socket, and dispatch to handler.
     * Might block on read, you may want to check with a Selector first.
     ***********************************************************************************/
    void dispatch_waiting();

private:
    char* _mountpoint;
    fuse_session * _fuse_session;
    fuse_chan * _fuse_chan;
    QSocketNotifier * _socketNotifier;
};

#endif // QFILESYSTEM_H
