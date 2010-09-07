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
private import tango.stdc.posix.signal;
private import tango.stdc.posix.sys.stat;
private import tango.stdc.posix.sys.statvfs;
private import tango.stdc.posix.utime;
private import tango.stdc.string;
private import tango.time.Clock;
private import tango.util.container.more.Heap;
private import tango.util.log.AppendConsole;
private import tango.util.log.LayoutDate;
private import tango.util.log.Log;

private import lib.arguments;
private import lib.client;
private import lib.fuse;
private import lib.hashes;
private import lib.message;
private import lib.pumping;

const HandleTimeoutTime = TimeSpan.fromMillis(100);
const HandleTimeoutLimit = 10;

/*-------------- Main program below ---------------*/
static BHFuseClient client;

struct AssetMap { // TODO: Is _probably_ not desired anymore.
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

class BHFuseClient : SimpleClient, IProcessor {
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

        // TODO: Implement again
/+        bool tryReconnect() {
            try connect(_remoteAddr);
            catch (Exception e) return false;

            assetMap.recycleThrough(&openAsset);
            throw new ReconnectedException; // Success! Inform callers
        }
        for (uint reconnectAttempts = 3; (reconnectAttempts > 0) && !tryReconnect(); reconnectAttempts--)
            Thread.sleep(3);+/
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
        uint refCount;

        this (char[] pathName, RemoteAsset asset) {
            this.pathName = pathName;
            this.asset = asset;
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
        stat_t create_stat_t(fuse_ino_t ino) {
            stat_t r;
            r.st_ino = ino;
            r.st_mode = S_IFREG | 0555;
            r.st_nlink = 1;
            r.st_size = size;
            return r;
        }

        /********************************************************************************
         * Make a FUSE-entry-reply for this INode and reply
         *******************************************************************************/
        void lookup(fuse_req_t req) {
            refCount += 1;
            fuse_entry_param reply;
            reply.ino = ino;
            reply.generation = 0;
            reply.attr = create_stat_t(reply.ino);
            reply.attr_timeout = double.max;
            reply.entry_timeout = 1;
            auto res = fuse_reply_entry(req, &reply);
            assert(res == 0);
        }

        /********************************************************************************
         * Handle a FUSE-open request for this INode and trigger reply
         *******************************************************************************/
        void open(OpenRequest r) {
            if (asset) {
                clearHandleTimeout();
                r.onBindResponse(asset, Status.SUCCESS, null);
            } else {
                client.open(ids, &r.onBindResponse);
            }
        }

        /********************************************************************************
         * Release resources held by an open INode.
         *******************************************************************************/
        void release() {
            if (asset) {
                asset.close;
                asset = null;
            }
            clearHandleTimeout();
        }

        /********************************************************************************
         * Handle a FUSE-read request for this INode and trigger reply
         *******************************************************************************/
        void read(ReadRequest r) {
            if (asset && !asset.closed) {
                asset.aSyncRead(r.offset, r.size, &r.onReadResponse);
            } else {
                r.onReadResponse(null, Status.INVALID_HANDLE, null, null);
            }
        }

        void forget(uint nlookup) {
            refCount -= nlookup;
            Stdout("Forgot to", refCount).newline;
            if (!refCount) {
                inodes.remove(asset.handle);
                inodeNameMap.remove(pathName);
                if (handleTimeout.callback) {
                    handleTimeouts.remove(&handleTimeout);
                    handleTimeout = handleTimeout.init;
                }
                asset.close();
            }
        }
    }

    /************************************************************************************
     * Hold details of a FUSE lookup-request, so we can store it over async call-
     * responses
     ***********************************************************************************/
    class LookupRequest {
        fuse_req_t req;
        char[] pathName;
        this(fuse_req_t req, char[] pathName) {
            this.req = req;
            this.pathName = pathName;
        }

        /********************************************************************************
         * Recieve bindResponse from bithorde, and answer to fuse.
         *******************************************************************************/
        void onBindResponse(IAsset _asset, Status sCode, AssetStatus s) {
            auto asset = cast(RemoteAsset)_asset;
            if (asset && (sCode == Status.SUCCESS)) {
                auto inode = new INode(pathName, asset);
                inode.lookup(req);
            } else {
                fuse_reply_err(req, ENOENT);
            }
        }
    }

    /************************************************************************************
     * Hold details of a FUSE open-request, so we can store it over async call-responses
     ***********************************************************************************/
    class OpenRequest {
        fuse_req_t req;
        fuse_file_info *fi;
        INode inode; // Need INode since we're attaching opened assets to it.
        this (fuse_req_t req, fuse_file_info *fi, INode inode) {
            this.req = req;
            this.fi = fi;
            this.inode = inode;
        }
        void onBindResponse(IAsset asset, Status sCode, AssetStatus status) {
            if (sCode == Status.SUCCESS) {
                inode.asset = cast(RemoteAsset)asset;
                fuse_reply_open(req, fi);
            } else {
                fuse_reply_err(req, ENOENT);
            }
        }
    }

    class ReadRequest {
        fuse_req_t req;
        fuse_file_info *fi;
        off_t offset;
        size_t size;
        this (fuse_req_t req, fuse_file_info *fi, off_t offset, size_t size) {
            this.req = req;
            this.fi = fi;
            this.offset = offset;
            this.size = size;
        }

        void onReadResponse(IAsset asset, Status sCode, lib.message.ReadRequest _, ReadResponse resp) {
            if ((sCode == Status.SUCCESS) &&
                (resp.offset <= offset) &&
                ((resp.offset+resp.content.length) >= (offset+size))) {
                auto data = resp.content;
                auto start = offset-resp.offset;
                auto end = start+size;
                fuse_reply_buf(req, cast(void*)(data[start..end].ptr), size);
            } else {
                fuse_reply_err(req, EBADF);
            }
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

    // Implement timeouts
    Time nextDeadline() {
        return handleTimeouts.size? handleTimeouts.peek.deadline : Time.max;
    }
    void processTimeouts(Time now) {
        while (handleTimeouts.size &&
            (handleTimeouts.peek.deadline <= now)) {
            handleTimeouts.peek.callback();
        }
    }
protected:
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
                auto ctx = new LookupRequest(req, name.dup);
                client.open(objectids, &ctx.onBindResponse);
            } else {
                fuse_reply_err(req, ENOENT);
            }
        }
    }
    void forget(fuse_ino_t ino, uint nlookup) {
        Stdout("Forgetting", ino).newline;
        if (auto asset = inoToAsset(ino))
            asset.forget(nlookup);
    }
    void getattr(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) {
        Stdout("Stat:ing", ino).newline;
        if (ino & 0b01) { // Is directory?
            ino >>= 1; // Right-shift 1
            if (ino == 0 || ((cast(HashType)ino) in HashMap)) {
                stat_t s;
                s.st_ino = ino;
                s.st_mode = S_IFDIR | 0555;
                s.st_nlink = 2;
                auto res = fuse_reply_attr(req, &s, double.max);
                assert(res == 0);
            } else {
                fuse_reply_err(req, ENOENT);
            }
        } else if (auto inode = inoToAsset(ino)) {
            auto s = inode.create_stat_t(ino);
            auto res = fuse_reply_attr(req, &s, double.max);
            assert(res == 0);
        } else {
            fuse_reply_err(req, ENOENT);
        }
    }
    void open(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) {
        if (auto inode = inoToAsset(ino)) {
            fi.keep_cache = true;
            inode.open(new OpenRequest(req, fi, inode));
        } else {
            fuse_reply_err(req, ENOENT);
        }
    }
    void release(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) {
        if (auto inode = inoToAsset(ino)) {
            inode.release();
            fuse_reply_err(req, 0);
        } else {
            fuse_reply_err(req, EBADF);
        }
    }
    void read(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, fuse_file_info *fi) {
        if (auto inode = inoToAsset(ino)) {
            inode.read(new ReadRequest(req, fi, off, size));
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
    auto oldmask = umask(0022);
    mountdir.create();
    umask(oldmask);
    scope BitHordeFilesystem fs = new BitHordeFilesystem(mountdir, client, arguments);

    auto pump = new Pump([cast(IProcessor)fs, client]);
    pump.run();
    return 0;
}
