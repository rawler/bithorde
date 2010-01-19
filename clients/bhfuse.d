module clients.fuse;

private import tango.core.Exception,
               tango.io.Stdout,
               tango.stdc.errno,
               tango.stdc.posix.fcntl,
               tango.stdc.posix.signal,
               tango.stdc.posix.sys.stat,
               tango.stdc.posix.sys.statvfs,
               tango.stdc.posix.utime,
               tango.stdc.string;

private import tango.net.device.Socket : Socket, SocketType, ProtocolType;
private import tango.net.device.LocalSocket;

private import lib.client,
               lib.message;

extern (C):
typedef int function(void *buf, char *name, stat_t *stbuf, off_t off) fuse_fill_dir_t;

struct fuse_conn_info {
    uint proto_major;
    uint proto_minor;
    uint async_read;
    uint max_write;
    uint max_readahead;
    uint reserved[27];
}

struct fuse_operations {
    int function(char *, stat_t *) getattr;
    int function(char *, char *, size_t) readlink;
    int function(char *, void *, void *) getdir; // Slightly changed from header. could not figure fuse_dirh_t
    int function(char *, mode_t, dev_t) mknod;
    int function(char *, mode_t) mkdir;
    int function(char *) unlink;
    int function(char *) rmdir;
    int function(char *, char *) symlink;
    int function(char *, char *) rename;
    int function(char *, char *) link;
    int function(char *, mode_t) chmod;
    int function(char *, uid_t, gid_t) chown;
    int function(char *, off_t) truncate;
    int function(char *, utimbuf *) utime;
    int function(char *, fuse_file_info *) open;
    int function(char *, void *, size_t, off_t, fuse_file_info *) read;
    int function(char *, void *, size_t, off_t, fuse_file_info *) write;
    int function(char *, statvfs_t *) statfs;
    int function(char *, fuse_file_info *) flush;
    int function(char *, fuse_file_info *) release;
    int function(char *, int, fuse_file_info *) fsync;
    int function(char *, char *, char *, size_t, int) setxattr;
    int function(char *, char *, char *, size_t) getxattr;
    int function(char *, char *, size_t) listxattr;
    int function(char *, char *) removexattr;
    int function(char *, fuse_file_info *) opendir;
    int function(char *, void *, fuse_fill_dir_t, off_t, fuse_file_info *) readdir;
    int function(char *, fuse_file_info *) releasedir;
    int function(char *, int, fuse_file_info *) fsyncdir;
    void *function(fuse_conn_info *conn) init;
    void function(void *) destroy;
    int function(char *, int) access;
    int function(char *, mode_t, fuse_file_info *) create;
    int function(char *, off_t, fuse_file_info *) ftruncate;
    int function(char *, stat_t *, fuse_file_info *) fgetattr;
    int function(char *, fuse_file_info *, int cmd, flock *) lock;
    int function(char *, timespec tv[2]) utimens;
    int function(char *, size_t blocksize, ulong *idx) bmap;
}

struct fuse_file_info {
    int flags;
    ulong fh_old;
    int writepage;
    uint direct_io = 1;
    uint keep_cache = 1;
    uint flush = 1;
    uint padding = 29;
    ulong fh;
    ulong lock_owner;
}

int fuse_main_real(int argc, char** argv, fuse_operations *op,
       size_t op_size, void *user_data);

/*-------------- Main program below ---------------*/

static IAsset[ubyte[]] fileMap;
static Client client;

extern (D) IAsset openAsset(ubyte[] objectid) {
    bool gotResponse = false;
    IAsset retval;
    pragma(msg, "BHFuse is currently out of commision (missing support for multi-id, and hashlink-parsing)");
/+    client.open(HashType.SHA1, objectid, delegate void(IAsset asset, Status status) {
        switch (status) {
        case Status.SUCCESS:
            retval = fileMap[objectid.dup] = asset;
            break;
        case Status.NOTFOUND:
            break;
        default:
            Stderr.format("Got unknown status from BitHorde.open: {}", status).newline;
        }
        gotResponse = true;
    });+/
    while (!gotResponse)
        client.readAndProcessMessage();
    return retval;
}

static int bh_getattr(char *path, stat_t *stbuf)
{
    int res = 0;
    char[] dpath = path[0..strlen(path)];

    memset(stbuf, 0, stat_t.sizeof);
    if (dpath == "/") {
        stbuf.st_mode = S_IFDIR | 0755;
        stbuf.st_nlink = 2;
    } else try {
        ubyte[100] buf;
        if (dpath.length > buf.length*2)
            return -ENOENT;
        auto objectid = hexToBytes(dpath[1..length], buf);
        IAsset asset;
        if (objectid in fileMap) {
            asset = fileMap[objectid];
        } else {
            asset = openAsset(objectid);
        }

        if (asset) {
            stbuf.st_mode = S_IFREG | 0444;
            stbuf.st_nlink = 1;
            stbuf.st_size = asset.size;
        } else {
            res = -ENOENT;
        }
    } catch (IllegalArgumentException) {
        res = -ENOENT;
    }

    return res;
}

static int bh_open(char *path, fuse_file_info *fi)
{
    if((fi.flags & 3) != O_RDONLY)
        return -EACCES;

    auto pathLen = strlen(path);
    if (pathLen < 2)
        return -ENOENT;
    try {
        ubyte[100] buf;
        if (pathLen > buf.length*2)
            return -ENOENT;
        ubyte[] objectid = hexToBytes(path[1..pathLen], buf);

        if ((objectid in fileMap) || openAsset(objectid))
            return 0;
        else
            return -ENOENT;
    } catch (IllegalArgumentException) {
        return -ENOENT;
    }
}

static int bh_read(char *path, void *buf, size_t size, off_t offset,
                      fuse_file_info *fi)
{
    auto pathLen = strlen(path);
    if (pathLen < 2)
        return -ENOENT;
    ubyte[] objectid;
    try {
        ubyte[100] oidbuf;
        if (pathLen > oidbuf.length*2)
            return -ENOENT;
        objectid = hexToBytes(path[1..pathLen], oidbuf);
    } catch (IllegalArgumentException)
        return -ENOENT;
    if (!(objectid in fileMap))
        return -ENOENT;
    auto asset = fileMap[objectid];
    bool gotResponse = false;

    if (offset < asset.size) {
        if (offset + size > asset.size)
            size = asset.size - offset;
        asset.aSyncRead(offset, size, delegate void(IAsset asset, Status status, ReadRequest req, ReadResponse resp) {
            switch (status) {
            case Status.SUCCESS:
                auto adjust = offset - resp.offset;
                if (adjust + size > resp.content.length)
                    size = resp.content.length - adjust;
                buf[0..size] = resp.content[adjust .. adjust+size];
                break;
            default:
                size = 0;
            }
            gotResponse = true;
        });
    } else {
        return 0;
    }

    while (true) synchronized(client) {
        if (gotResponse)
            break;
        client.readAndProcessMessage();
    }
    return size;
}

static fuse_operations bh_oper = {
    getattr : &bh_getattr,
    open    : &bh_open,
    read    : &bh_read,
};

extern (D):
int main(char[][] args)
{
    auto addr = new LocalAddress("/tmp/bithorde");
    client = new Client(addr, "bhfuse");

    scope char** argv = cast(char**)new char*[args.length];
    foreach (idx,arg; args) {
        arg.length = arg.length + 1;
        arg[length-1] = 0;
        argv[idx] = arg.ptr;
    }
    return fuse_main_real(args.length, argv, &bh_oper, bh_oper.sizeof, null);
}
