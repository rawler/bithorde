/****************************************************************************************
 *   Copyright: Copyright (C) 2009-2010 Ulrik Mikaelsson. All rights reserved
 *
 *   License:
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 ***************************************************************************************/
module clients.fuse;

private import tango.core.Exception;
private import tango.io.selector.Selector;
private import tango.io.Stdout;
private import tango.net.device.LocalSocket;
private import tango.stdc.errno;
private import tango.stdc.posix.fcntl;
private import tango.stdc.posix.signal;
private import tango.stdc.posix.sys.stat;
private import tango.stdc.posix.sys.statvfs;
private import tango.stdc.posix.utime;
private import tango.stdc.string;

private import lib.client;
private import lib.hashes;
private import lib.message;

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
    uint options; // The C struct uses a bitfield here. We use an int with accessors below
    ulong fh;
    ulong lock_owner;

    bool direct_io() { return cast(bool)(options & (1<<0)); }
    bool direct_io(bool b) { options |= (b<<0); return b; }

    bool keep_cache() { return cast(bool)(options & (1<<1)); }
    bool keep_cache(bool b) { options |= (b<<1); return b; }

    bool flush() { return cast(bool)(options & (1<<2)); }
    bool flush(bool b) { options |= (b<<2); return b; }

    bool nonseekable() { return cast(bool)(options & (1<<3)); }
    bool nonseekable(bool b) { options |= (b<<3); return b; }
}

int fuse_main_real(int argc, char** argv, fuse_operations *op,
       size_t op_size, void *user_data);

/*-------------- Main program below ---------------*/

static SimpleClient client;

extern (D) {
    struct AssetMap {
        static RemoteAsset[] _assetMap;
        RemoteAsset opIndex(uint idx) {
            return _assetMap[idx];
        }
        RemoteAsset opIndexAssign(RemoteAsset asset, uint idx) in {
            assert(idx < 32768, "Not sensible with thousands of open assets");
        } body {
            if (idx >= _assetMap.length)
                _assetMap.length = (_assetMap.length*2) + 2; // Grow
            return _assetMap[idx] = asset;
        }
    }
    static AssetMap assetMap;

    void driveUntil(ref bool doBreak) {
        synchronized (client) {
            while (!doBreak)
                client.pump();
        }
    }

    RemoteAsset openAsset(Identifier[] objectids) {
        bool gotResponse = false;
        RemoteAsset retval;
        client.open(objectids, delegate void(IAsset asset, Status status, OpenOrUploadRequest req, OpenResponse resp) {
            switch (status) {
            case Status.SUCCESS:
                retval = cast(RemoteAsset)asset;
                break;
            case Status.NOTFOUND:
                break;
            default:
                Stderr.format("Got unknown status from BitHorde.open: {}", status).newline;
            }
            gotResponse = true;
        });
        driveUntil(gotResponse);
        return retval;
    }
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
        char[] name;
        auto objectids = parseMagnet(dpath[1..length], name);
        if (!objectids.length)
            return -ENOENT;

        if (auto asset = openAsset(objectids)) {
            stbuf.st_mode = S_IFREG | 0444;
            stbuf.st_nlink = 1;
            stbuf.st_size = asset.size;
            asset.close();
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
    if (pathLen < 10)
        return -ENOENT;
    else try {
        char[] name;
        auto objectids = parseMagnet(path[1..pathLen], name);

        if (auto asset = openAsset(objectids)) {
            assetMap[asset.handle] = asset;
            fi.fh = asset.handle;
            fi.keep_cache = true;
            return 0;
        } else {
            return -ENOENT;
        }
    } catch (IllegalArgumentException) {
        return -ENOENT;
    }
}

static int bh_read(char *path, void *buf, size_t size, off_t offset,
                      fuse_file_info *fi)
{
    if (!fi)
        return -EBADF;
    auto asset = assetMap[fi.fh];
    if (!asset)
        return -EBADF;

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

    driveUntil(gotResponse);
    return size;
}

static int bh_close(char *path, void *buf, size_t size, off_t offset,
                      fuse_file_info *fi)
{
    if (!fi)
        return -ENOENT;

    auto asset = assetMap[fi.fh];
    asset.close();
    assetMap[fi.fh] = null;
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
    client = new SimpleClient(addr, "bhfuse");

    scope char** argv = cast(char**)new char*[args.length];
    foreach (idx,arg; args) {
        arg.length = arg.length + 1;
        arg[length-1] = 0;
        argv[idx] = arg.ptr;
    }
    return fuse_main_real(args.length, argv, &bh_oper, bh_oper.sizeof, null);
}
