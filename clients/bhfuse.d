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
private import tango.core.Signal;
private import tango.core.tools.TraceExceptions;
private import tango.io.FilePath;
private import tango.io.selector.Selector;
private import tango.io.Stdout;
private import tango.net.device.Berkeley : Address;
private import tango.net.device.LocalSocket;
private import tango.net.device.Socket : Socket;
private import tango.stdc.errno;
private import tango.stdc.posix.fcntl;
private import tango.stdc.posix.grp;
private import tango.stdc.posix.pwd;
private import tango.stdc.posix.signal;
private import tango.stdc.posix.sys.stat;
private import tango.stdc.posix.sys.statvfs;
private import tango.stdc.posix.unistd;
private import tango.stdc.posix.utime;
private import tango.stdc.string;
private import tango.time.Clock;
private import tango.util.container.more.Heap;
private import tango.util.log.AppendConsole;
private import tango.util.log.LayoutDate;
private import tango.util.log.Log;

private import lib.arguments;
private import lib.cachedalloc;
private import lib.client;
private import lib.fuse;
private import lib.hashes;
private import lib.message;
private import lib.pumping;

const HandleTimeoutTime = TimeSpan.fromMillis(100);
const HandleTimeoutLimit = 10;

/*-------------- Main program below ---------------*/
class BHFuseClient : SimpleClient, IProcessor {
    private Address _remoteAddr;

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

        // TODO: Implement reconnection again
    }

    protected Socket currentConnection;
    protected Signal!(Socket) newConnection;

    protected Socket connect(Address addr) {
        currentConnection = super.connect(addr);
        newConnection(currentConnection);
        return currentConnection;
    }
public: // IProcessor interface-implementation
    ISelectable[] conduits() {
        return [currentConnection];
    }
    void process(ref SelectionKey key) { super.process(key); }
    Time nextDeadline() { return super.nextDeadline; }
    void processTimeouts(Time now) { super.processTimeouts(now); }
}

class BitHordeFilesystem : Filesystem {
    class INode {
        struct TimeoutHandle {
            Time deadline;
            void delegate() callback;
            int opCmp(TimeoutHandle other) {
                return this.deadline.opCmp(other.deadline);
            }
            bool opEquals(typeof(callback) cb) {
                return this.callback == cb;
            }
        }

        RemoteAsset asset;
        TimeoutHandle handleTimeout;
        char[] pathName;
        Identifier[] ids;
        ulong size;
        ino_t ino;
        uint openCount;

        this (char[] pathName, RemoteAsset asset) {
            this.pathName = pathName;
            this.asset = asset;
            this.openCount = 1;
            this.ids = asset.requestIds;
            this.size = asset.size;
            this.ino = allocateIno;
            setHandleTimeout();
            inodes[ino] = this;
            inodeNameMap[pathName] = this;
        }

        /********************************************************************************
         * Register a pending handleTimeout.
         *******************************************************************************/
        void setHandleTimeout() {
            handleTimeout.deadline = Clock.now + HandleTimeoutTime;
            handleTimeout.callback = &this.release;
            handleTimeouts.push(&handleTimeout);
            if (handleTimeouts.size > HandleTimeoutLimit) // Keep a ceiling on number of handles
                handleTimeouts.peek().callback();
        }

        /********************************************************************************
         * If there is a handleTimeout pending for this INode, release it.
         *******************************************************************************/
        void clearHandleTimeout() {
            if (handleTimeout.callback) {
                handleTimeouts.remove(&handleTimeout);
                handleTimeout = handleTimeout.init;
            }
        }

        /********************************************************************************
         * Fill in stat_t structure for lookup or stat
         *******************************************************************************/
        void fill_stat_t(out stat_t r) {
            r.st_ino = ino;
            r.st_mode = S_IFREG | 0555;
            r.st_nlink = 1;
            r.st_size = size;
        }

        /********************************************************************************
         * Make a FUSE-entry-reply for this INode and reply
         *******************************************************************************/
        void lookup(fuse_req_t req) {
            fuse_entry_param reply;
            reply.ino = ino;
            reply.generation = 0;
            fill_stat_t(reply.attr);
            reply.attr_timeout = double.max;
            reply.entry_timeout = 1;
            auto res = fuse_reply_entry(req, &reply);
            assert(res == 0);
        }

        /********************************************************************************
         * Handle a FUSE-open request for this INode and trigger reply
         *******************************************************************************/
        void open(OpenRequest* r) {
            if (asset) {
                clearHandleTimeout();
                openCount += 1;
                r.onBindResponse(asset, Status.SUCCESS, null);
            } else {
                client.open(ids, &r.onBindResponse);
            }
        }

        /********************************************************************************
         * Decrement openCounter. If zero, release resources held by an open INode.
         *******************************************************************************/
        void release() {
            if (asset && (--openCount == 0) ) {
                asset.close;
                asset = null;
            }
            clearHandleTimeout();
        }

        /********************************************************************************
         * Handle a FUSE-read request for this INode and trigger reply
         *******************************************************************************/
        void read(ReadRequest* r) {
            if (r.size == 0) {
                r.onReadResponse(null, Status.SUCCESS, null, null);
            } else if (asset && !asset.closed) {
                asset.aSyncRead(r.offset, r.size, &r.onReadResponse);
            } else {
                r.onReadResponse(null, Status.INVALID_HANDLE, null, null);
            }
        }
    }

    /************************************************************************************
     * Hold details of a FUSE lookup-request, so we can store it over async call-
     * responses
     ***********************************************************************************/
    struct LookupRequest {
        mixin CachedAllocation!(16, size_t.sizeof*4);
        fuse_req_t req;
        char[] pathName;
        BitHordeFilesystem fs;

        /********************************************************************************
         * Recieve bindResponse from bithorde, and answer to fuse.
         *******************************************************************************/
        void onBindResponse(IAsset _asset, Status sCode, AssetStatus s) {
            auto asset = cast(RemoteAsset)_asset;
            if (asset && (sCode == Status.SUCCESS)) {
                auto inode = fs.new INode(pathName, asset);
                inode.lookup(req);
            } else {
                fuse_reply_err(req, ENOENT);
            }
            delete this;
        }
    }

    /************************************************************************************
     * Hold details of a FUSE open-request, so we can store it over async call-responses
     ***********************************************************************************/
    struct OpenRequest {
        mixin CachedAllocation!(16, size_t.sizeof*3);
        fuse_req_t req;
        fuse_file_info *fi;
        INode inode; // Need INode since we're attaching opened assets to it.
        void onBindResponse(IAsset asset, Status sCode, AssetStatus status) {
            if (sCode == Status.SUCCESS) {
                inode.openCount += 1;
                inode.asset = cast(RemoteAsset)asset;
                fuse_reply_open(req, fi);
            } else {
                fuse_reply_err(req, ENOENT);
            }
            delete this;
        }
    }

    /************************************************************************************
     * Async store details regarding a single-read-request, in order to feed back
     * result to Fuse.
     ***********************************************************************************/
    struct ReadRequest {
        mixin CachedAllocation!(16, 8+size_t.sizeof*3);
        fuse_req_t req;
        fuse_file_info *fi;
        off_t offset;
        size_t size;

        void onReadResponse(IAsset _asset, Status sCode, lib.message.ReadRequest _, ReadResponse resp) {
            if (size == 0) { // EOF, we have not requested anything
                fuse_reply_buf(req, null, size);
            } else if ((sCode == Status.SUCCESS) &&
                (resp.offset <= offset) &&
                ((resp.offset+resp.content.length) >= (offset+size))) {
                auto data = resp.content;
                auto start = offset-resp.offset;
                auto end = start+size;
                fuse_reply_buf(req, cast(void*)(data[start..end].ptr), size);
            } else {
                fuse_reply_err(req, EBADF);
            }
            delete this;
        }
    }
private:
    BHFuseClient client;
    INode[uint] inodes;
    INode[char[]] inodeNameMap;
    fuse_ino_t ino = 2;
    fuse_ino_t allocateIno() {return ino++;}
    Heap!(INode.TimeoutHandle*, true) handleTimeouts;
    INode inoToAsset(fuse_ino_t ino) {
        auto ptr = ino in inodes;
        if (ptr)
            return *ptr;
        else
            return null;
    }
public:
    this(FilePath mountpoint, BHFuseClient client, FUSEArguments args) {
        // TODO: deal with arguments
        char[][] fuse_args = ["bhfuse", "-ofsname=bhfuse", "-oallow_other"];
        if (args.do_debug)
            fuse_args ~= "-d";
        super(mountpoint.toString, fuse_args);
        this.client = client;
    }

    /************************************************************************************
     * When do we need to process our next timeout?
     ***********************************************************************************/
    Time nextDeadline() {
        return handleTimeouts.size? handleTimeouts.peek.deadline : Time.max;
    }

    /************************************************************************************
     * Process all timeouts up until (now)
     ***********************************************************************************/
    void processTimeouts(Time now) {
        while (handleTimeouts.size &&
            (handleTimeouts.peek.deadline <= now)) {
            handleTimeouts.peek.callback();
        }
    }

protected:
    /************************************************************************************
     * FUSE-hook for mapping a name in a directory to an inode.
     ***********************************************************************************/
    void lookup(fuse_req_t req, fuse_ino_t parent, char *_name) {
        auto name = _name[0..strlen(_name)];
        if (name in inodeNameMap) {
            auto inode = inodeNameMap[name];
            inode.lookup(req);
        } else if ((parent == ROOT_INODE) && (name in HashNameMap)) {
            fuse_entry_param reply;
            reply.ino = (HashNameMap[name].pbType << 1) | 0b1;
            reply.generation = 1;
            reply.attr.st_ino = reply.ino;
            reply.attr.st_mode = S_IFDIR | 0555;
            reply.attr.st_nlink = 2;
            reply.attr_timeout = double.max;
            reply.entry_timeout = double.max;
            auto res = fuse_reply_entry(req, &reply);
            assert(res == 0);
        } else {
            char[] _;
            auto objectids = parseUri(name, _);
            if (objectids.length) {
                auto ctx = new LookupRequest;
                ctx.req = req;
                ctx.pathName = name;
                ctx.fs = this;
                client.open(objectids, &ctx.onBindResponse);
            } else {
                fuse_reply_err(req, ENOENT);
            }
        }
    }

    /************************************************************************************
     * FUSE-hook informing that an INode may be forgotten
     * TODO: potentially unsafe needs investigation
     ***********************************************************************************/
    void forget(fuse_ino_t ino, c_ulong nlookup) {
    }

    /************************************************************************************
     * FUSE-hook for fetching attributes of an INode
     ***********************************************************************************/
    void getattr(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) {
        if (ino == ROOT_INODE) { // Is root?
            stat_t s;
            s.st_ino = ino;
            s.st_mode = S_IFDIR | 0555;
            s.st_nlink = 2;
            auto res = fuse_reply_attr(req, &s, double.max);
            assert(res == 0);
        } else if (auto inode = inoToAsset(ino)) {
            stat_t s;
            inode.fill_stat_t(s);
            auto res = fuse_reply_attr(req, &s, double.max);
            assert(res == 0);
        } else {
            fuse_reply_err(req, ENOENT);
        }
    }

    /************************************************************************************
     * FUSE-hook for open()ing an INode
     ***********************************************************************************/
    void open(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) {
        if (auto inode = inoToAsset(ino)) {
            fi.keep_cache = true;
            auto ctx = new OpenRequest;
            ctx.req = req;
            ctx.fi = fi;
            ctx.inode = inode;
            inode.open(ctx);
        } else {
            fuse_reply_err(req, ENOENT);
        }
    }

    /************************************************************************************
     * FUSE-hook for close()ing an INode
     ***********************************************************************************/
    void release(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) {
        if (auto inode = inoToAsset(ino)) {
            inode.release();
            fuse_reply_err(req, 0);
        } else {
            fuse_reply_err(req, EBADF);
        }
    }

    /************************************************************************************
     * FUSE-hook for read()ing from an open INode
     ***********************************************************************************/
    void read(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, fuse_file_info *fi) {
        if (auto inode = inoToAsset(ino)) {
            assert(off <= inode.size, "FUSE sent offset after Eof");
            if ((off+size) > inode.size) // Limit to Eof
                size = inode.size - off;
            auto ctx = new ReadRequest;
            ctx.req = req;
            ctx.fi = fi;
            ctx.offset = off;
            ctx.size = size;
            inode.read(ctx);
        } else {
            fuse_reply_err(req, EBADF);
        }
    }
}

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

/****************************************************************************************
 * BHFuse main routine. Parse arguments, connect to BitHorde, and mount Filesystem.
 ***************************************************************************************/
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

    if (arguments.do_debug)
        Log.root.level = Level.Trace;
    else
        Log.root.level = Level.Info;
    Log.root.add(new AppendConsole(new LayoutDate));

    auto addr = new LocalAddress(arguments.sockPath);
    auto client = new BHFuseClient(addr, "bhfuse");

    auto mountdir = FilePath(arguments.mountpoint).absolute("/");
    auto oldmask = umask(0022);
    mountdir.create();
    umask(oldmask);
    scope BitHordeFilesystem fs = new BitHordeFilesystem(mountdir, client, arguments);

    if (geteuid() == 0) {
        auto log = Log.lookup("main");
        Log.lookup("main").info("Detected running as root. Dropping privileges to nobody");
        if (auto nogroup = getgrnam("nogroup")) {
            if (setegid(nogroup.gr_gid))
                log.error("Failed dropping group-privileges. Running with root privileges!");
        } else {
            log.error("Did not find user 'group'. Running with root privileges!");
        }

        if (auto nobody = getpwnam("nobody")) {
            if (seteuid(nobody.pw_uid))
                log.error("Failed dropping user-privileges. Running with root privileges!");
        } else {
            log.error("Did not find user 'nobody'. Running with root privileges!");
        }
    }

    auto pump = new Pump([cast(IProcessor)fs, client]);
    pump.run();
    return 0;
}
