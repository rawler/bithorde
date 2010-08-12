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
private import tango.core.Thread;
private import tango.core.tools.TraceExceptions;
private import tango.io.FilePath;
private import tango.io.selector.Selector;
private import tango.io.Stdout;
private import tango.net.device.Berkeley : Address;
private import tango.net.device.LocalSocket;
private import tango.stdc.errno;
private import tango.stdc.posix.fcntl;
private import tango.stdc.posix.signal;
private import tango.stdc.posix.sys.stat;
private import tango.stdc.posix.sys.statvfs;
private import tango.stdc.posix.utime;
private import tango.stdc.string;
private import tango.util.log.AppendConsole;
private import tango.util.log.LayoutDate;
private import tango.util.log.Log;

private import lib.arguments;
private import lib.client;
private import lib.hashes;
private import lib.message;

extern (C):
typedef int function(void *buf, char *name, stat_t *stbuf, off_t off) fuse_fill_dir_t;

alias void fuse_t;

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

struct fuse_context {
    fuse_t* fuse;       /// Pointer to the fuse object
    uid_t uid;          /// User ID of the calling process
    gid_t gid;          /// Group ID of the calling process
    pid_t pid;          /// Thread ID of the calling process
    void *private_data; /// Private filesystem data
    mode_t umask;       /// Umask of the calling process (introduced in version 2.8)
};

int fuse_main_real(int argc, char** argv, fuse_operations *op, size_t op_size,
        void *user_data);
fuse_context* fuse_get_context();
void fuse_exit(fuse_t* fuse);
fuse_t* fuse_setup (int argc, char** argv, fuse_operations *op, size_t op_size,
        char** mountpoint, int* multithreaded, void* user_data);
int fuse_loop (fuse_t* f);
void fuse_teardown (fuse_t* fuse, char * mountpoint);

/*-------------- Main program below ---------------*/
extern (D) {
    static BHFuseClient client;

    struct AssetMap {
        RemoteAsset[] _assetMap;

        /********************************************************************************
         * Read out an asset by index
         *******************************************************************************/
        RemoteAsset opIndex(uint idx) {
            return _assetMap[idx];
        }
        /********************************************************************************
         * Assign an asset to index
         *******************************************************************************/
        RemoteAsset opIndexAssign(RemoteAsset asset, uint idx) in {
            assert(idx < 32768, "Not sensible with thousands of open assets");
        } body {
            if (idx >= _assetMap.length)
                _assetMap.length = (_assetMap.length*2) + 2; // Grow
            return _assetMap[idx] = asset;
        }

        void recycleThrough(RemoteAsset delegate(Identifier[] objectids) openMethod) {
            foreach (ref asset; _assetMap) {
                if (asset)
                    asset = openMethod(asset.requestIds);
            }
        }
    }

    class BitHordeException : Exception {
        Status status;
        this(Status status) {
            this.status = status;
            super(statusToString(status));
        }
    }

    class BHFuseClient : SimpleClient {
        private Address _remoteAddr;
        AssetMap assetMap;

        this(Address addr, char[] myname) {
            _remoteAddr = addr;
            super(addr, myname);
        }

        /********************************************************************************
         * Thrown when theres no hope of reconnecting. At this point, Fuse is already
         * prepared for shutting down.
         *******************************************************************************/
        class DisconnectedException : Exception {
            this() { super("Disconnected"); }
        }

        /********************************************************************************
         * Thrown when reconnect has succeeded. Recieving code should retry last attempt
         *******************************************************************************/
        class ReconnectedException : Exception {
            this() { super("Reconnected"); }
        }

        /********************************************************************************
         * Tries to reconnect. Will not return normally, only return is either
         * ReconnectedException, which will allow calling code to trigger retry, or
         * DisconnectedException, at which point fuse will already be prepared for
         * termination
         *******************************************************************************/
        void onDisconnected() {
            super.onDisconnected();

            bool tryReconnect() {
                try connect(_remoteAddr);
                catch (Exception e) return false;

                assetMap.recycleThrough(&openAsset);
                throw new ReconnectedException; // Success! Inform callers
            }
            for (uint reconnectAttempts = 3; (reconnectAttempts > 0) && !tryReconnect(); reconnectAttempts--)
                Thread.sleep(3);

            // Will only get here if no reconnect-attempt succeeded. Terminate FUSE and inform callers
            auto ctx = fuse_get_context();
            fuse_exit(ctx.fuse);
            throw new DisconnectedException;
        }

        /********************************************************************************
         * Try to Asset, while driving client
         *******************************************************************************/
        RemoteAsset openAsset(Identifier[] objectids) {
            RemoteAsset retval;
            for (auto retries = 2; retries > 0; retries--) try {
                bool gotResponse = false;
                open(objectids, delegate void(IAsset asset, Status status, AssetStatus resp) {
                    if (status == Status.SUCCESS) {
                        retval = cast(RemoteAsset)asset;
                    } else {
                        Stderr.format("Got non-success status from BitHorde.open: {}", statusToString(status)).newline;
                        throw new BitHordeException(status);
                    }
                    gotResponse = true;
                });
                driveUntil(gotResponse);
                break;
            } catch (ReconnectedException e) { continue; } // Retry

            return retval;
        }

        /********************************************************************************
         * Try to stat() asset, while driving client
         *******************************************************************************/
        ulong statAsset(Identifier[] objectids) {
            ulong retval;
            for (auto retries = 2; retries > 0; retries--) try {
                bool gotResponse = false;
                open(objectids, delegate void(IAsset asset, Status status, AssetStatus resp) {
                    scope(exit) asset.close();
                    if (status == Status.SUCCESS) {
                        retval = resp.size;
                    } else {
                        Stderr.format("Got non-success status from BitHorde.open: {}", statusToString(status)).newline;
                        throw new BitHordeException(status);
                    }
                    gotResponse = true;
                });
                driveUntil(gotResponse);
                break;
            } catch (ReconnectedException e) { continue; } // Retry

            return retval;
        }

        /********************************************************************************
         * Lets threads take turns pumping the client, until it signals satisfaction
         * through the referenced doBreak boolean
         *******************************************************************************/
        void driveUntil(ref bool doBreak) {
            while (!doBreak)
                client.pump();
        }
    }
}

/****************************************************************************************
 * GETATTR Fuse-operation-handler
 ***************************************************************************************/
static int bh_getattr(char *path, stat_t *stbuf)
{
    char[] dpath = path[0..strlen(path)];

    memset(stbuf, 0, stat_t.sizeof);
    if (dpath == "/") {
        stbuf.st_mode = S_IFDIR | 0755;
        stbuf.st_nlink = 2;
        return 0;
    } else try {
        char[] name;
        auto objectids = parseUri(dpath[1..length], name);
        if (!objectids.length)
            return -ENOENT;

        if (auto size = client.statAsset(objectids)) {
            stbuf.st_mode = S_IFREG | 0444;
            stbuf.st_nlink = 1;
            stbuf.st_size = size;
            return 0; // Success
        } else {
            return -ENOENT;
        }
    } catch (BitHordeException e) {
        switch (e.status) {
            case Status.NORESOURCES:
                return -ENOMEM;
                break;
            default:
                return -ENOENT;
        }
    } catch (IllegalArgumentException) {
        return -ENOENT;
    } catch (BHFuseClient.DisconnectedException) {
        return -ENOTCONN;
    } catch (Exception e) {
        void write(char[] x) {
            Stderr(x);
        }
        e.writeOut(&write);
        Stderr.newline;
        return -ENOENT;
    }
}

/****************************************************************************************
 * OPEN Fuse-operation-handler
 ***************************************************************************************/
static int bh_open(char *path, fuse_file_info *fi)
{
    if((fi.flags & 3) != O_RDONLY)
        return -EACCES;

    auto pathLen = strlen(path);
    if (pathLen < 10)
        return -ENOENT;
    else try {
        char[] name;
        auto objectids = parseUri(path[1..pathLen], name);

        if (auto asset = client.openAsset(objectids)) {
            client.assetMap[asset.handle] = asset;
            fi.fh = asset.handle;
            fi.keep_cache = true;
            return 0;
        } else {
            return -ENOENT;
        }
    } catch (BitHordeException e) {
        switch (e.status) {
            case Status.NORESOURCES:
                return -ENOMEM;
                break;
            default:
                return -ENOENT;
        }
    } catch (IllegalArgumentException) {
        return -ENOENT;
    } catch (BHFuseClient.DisconnectedException) {
        return -ENOTCONN;
    }
}

/****************************************************************************************
 * READ Fuse-operation-handler
 ***************************************************************************************/
static int bh_read(char *path, void *buf, size_t size, off_t offset,
                      fuse_file_info *fi)
{
    if (!fi)
        return -EBADF;
    auto asset = client.assetMap[fi.fh];

    if (offset < asset.size) {
        if (offset + size > asset.size)
            size = asset.size - offset;

        for (auto retry=2; retry > 0; retry--) try {
            if (!asset)
                return -EBADF;
            bool gotResponse = false;
            asset.aSyncRead(offset, size, delegate void(IAsset asset, Status status, ReadRequest req, ReadResponse resp) {
                switch (status) {
                case Status.SUCCESS:
                    auto adjust = offset - resp.offset;
                    if (adjust + size > resp.content.length)
                        size = resp.content.length - adjust;
                    buf[0..size] = resp.content[adjust .. adjust+size];
                    break;
                case Status.DISCONNECTED:
                    break;
                default:
                    size = 0;
                }
                gotResponse = true;
            });
            client.driveUntil(gotResponse);
        } catch (BHFuseClient.ReconnectedException e) {
            asset = client.assetMap[fi.fh];
            continue; // Retry request
        } catch (BHFuseClient.DisconnectedException e) {
            return -ENOTCONN;
        }
    } else {
        return 0;
    }

    return size;
}

/****************************************************************************************
 * RELEASE Fuse-operation-handler
 ***************************************************************************************/
static int bh_release(char *path, fuse_file_info *fi)
{
    if (!fi)
        return -ENOENT;

    try {
        auto asset = client.assetMap[fi.fh];
        if (asset) {
            client.assetMap[fi.fh] = null;
            asset.close();
        }
    } catch {} // Whatever goes wrong, Do Nothing

    return 0;
}

/****************************************************************************************
 * BHFUSE-operations-matrix
 ***************************************************************************************/
static fuse_operations bh_oper = {
    getattr : &bh_getattr,
    open    : &bh_open,
    read    : &bh_read,
    release : &bh_release,
};

extern (D):
/****************************************************************************************
 * BHFuse-implementation of Argument-parsing.
 ***************************************************************************************/
class FUSEArguments : protected Arguments {
private:
    char[] sockPath;
    char[] mountpoint;
    bool do_debug;
public:
    /************************************************************************************
     * Setup and configure underlying parser.
     ***********************************************************************************/
    this() {
        this["debug"].aliased('d').smush;
        this["unixsocket"].aliased('u').params(1).smush.defaults("/tmp/bithorde");
        this[null].title("mountpoint").required.params(1);
    }

    /************************************************************************************
     * Do the real parsing and convert to plain D-attributes.
     ***********************************************************************************/
    bool parse(char[][] arguments) {
        if (!super.parse(arguments))
            throw new IllegalArgumentException("Failed to parse arguments:\n" ~ errors(&stderr.layout.sprint));

        do_debug = this["debug"].set;
        sockPath = this["unixsocket"].assigned[0];
        mountpoint = this[null].assigned[0];

        return true;
    }
}

int main(char[][] args)
{
    auto arguments = new FUSEArguments;
    try {
        arguments.parse(args[1..length]);
    } catch (IllegalArgumentException e) {
        if (e.msg)
            Stderr(e.msg).newline;
        Stderr.format("Usage: {} [--debug|-d] [--unixsocket|u=/tmp/bithorde] <mount-point>", args[0]).newline;
        return -1;
    }

    auto addr = new LocalAddress(arguments.sockPath);
    client = new BHFuseClient(addr, "bhfuse");

    if (arguments.do_debug)
        Log.root.level = Level.Trace;
    Log.root.add(new AppendConsole(new LayoutDate));

    auto mountdir = FilePath(arguments.mountpoint).absolute("/");
    mountdir.create();
    auto cmountpoint = arguments.mountpoint~'\0';
    auto cbinname = args[0] ~ '\0';
    auto argv = new char*[0];
    argv ~= cbinname.ptr;
    if (arguments.do_debug)
        argv ~= "-d\0".ptr;
    argv ~= cmountpoint.ptr;
    char* parsedmountpoint;
    int multithreaded;

    auto fusehandle = fuse_setup(argv.length, argv.ptr, &bh_oper, bh_oper.sizeof, &parsedmountpoint, &multithreaded, null);
    scope (exit) fuse_teardown(fusehandle, parsedmountpoint);
    if (fusehandle)
        return fuse_loop(fusehandle);
    else
        return 0;
}
