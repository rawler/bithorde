/*
 * FUSE: Filesystem in Userspace
 *  is Copyright (C) 2001-2007  Miklos Szeredi <miklos@szeredi.hu>
 *
 * This D-binding:
 *  is Copyright (C) 2010 Ulrik Mikaelsson <ulrik.mikaelsson@gmail.com>
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

*/
import tango.io.model.IConduit;
import tango.stdc.posix.sys.stat;
import tango.sys.consts.errno;
import tango.time.Time;

import lib.pumping;

pragma(lib, "fuse");

extern(C) {
    const ROOT_INODE = 1;
    alias void* fuse_session;
    alias void* fuse_chan;
    struct fuse_args {
        int argc;
        char ** argv;
        int _allocated = 0;
        bool allocated() { return cast(bool)_allocated; }
        bool allocated(bool val) { return cast(bool)(_allocated = val); }
        static fuse_args fromD(char[][] args) {
            fuse_args a;
            a.argc = args.length;
            a.argv = (new char*[a.argc]).ptr;
            foreach (i, arg; args)
                a.argv[i] = (arg~'\0').ptr;
            return a;
        }
    }
    alias void* fuse_req_t;
    alias uint fuse_ino_t;
    alias void* fuse_conn_info;

    struct fuse_entry_param {
        fuse_ino_t ino;
        uint       generation;
        stat_t     attr;
        double     attr_timeout;
        double     entry_timeout;
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

    struct fuse_lowlevel_ops {
        void function(void *userdata, fuse_conn_info conn) init;
        void function(void *userdata) destroy;
        void function(fuse_req_t req, fuse_ino_t parent, char *name) lookup;
        void function(fuse_req_t req, fuse_ino_t ino, uint nlookup) forget;
        void function(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) getattr;
        void function(fuse_req_t req, fuse_ino_t ino, stat_t *attr, int to_set, fuse_file_info *fi) setattr;
        void function(fuse_req_t req, fuse_ino_t ino) readlink;
        void function(fuse_req_t req, fuse_ino_t parent, char *name, mode_t mode, dev_t rdev) mknod;
        void function(fuse_req_t req, fuse_ino_t parent, char *name, mode_t mode) mkdir;
        void function(fuse_req_t req, fuse_ino_t parent, char *name) unlink;
        void function(fuse_req_t req, fuse_ino_t parent, char *name) rmdir;
        void function(fuse_req_t req, char *link, fuse_ino_t parent, char *name) symlink;
        void function(fuse_req_t req, fuse_ino_t parent, char *name, fuse_ino_t newparent, char *newname) rename;
        void function(fuse_req_t req, fuse_ino_t ino, fuse_ino_t newparent, char *newname) link;
        void function(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) open;
        void function(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, fuse_file_info *fi) read;
        void function(fuse_req_t req, fuse_ino_t ino, char *buf, size_t size, off_t off, fuse_file_info *fi) write;
        void function(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) flush;
        void function(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) release;
    }
    size_t       fuse_chan_bufsize (fuse_chan ch);
    int          fuse_chan_fd(fuse_chan ch);
    int          fuse_chan_recv(fuse_chan *ch, ubyte *buf, size_t size);
    fuse_session fuse_lowlevel_new(fuse_args* args, fuse_lowlevel_ops* op, size_t op_size, void* userdata);
    int          fuse_opt_add_arg(fuse_args* args, char* arg);
    int          fuse_reply_attr(fuse_req_t req, stat_t *attr, double attr_timeout);
    int          fuse_reply_buf(fuse_req_t req, void *buf, size_t size);
    int          fuse_reply_entry(fuse_req_t req, fuse_entry_param* e);
    int          fuse_reply_err(fuse_req_t req, int err);
    void         fuse_reply_none(fuse_req_t req);
    int          fuse_reply_open(fuse_req_t req, fuse_file_info *fi);
    void*        fuse_req_userdata(fuse_req_t req);
    void         fuse_session_add_chan(fuse_session se, fuse_chan ch);
    void         fuse_session_destroy(fuse_session se);
    int          fuse_session_exited(fuse_session se);
    fuse_chan    fuse_session_next_chan(fuse_session se, fuse_chan ch);
    void         fuse_session_process(fuse_session se, ubyte *buf, size_t len, fuse_chan ch);

    fuse_chan    fuse_mount(char* mountpoint, fuse_args* args);
    void         fuse_unmount(char* mountpoint, fuse_chan ch);
}

abstract class Filesystem : ISelectable, IProcessor {
private:
    char[] mountpoint;
    fuse_session s;
    fuse_chan chan;
    ubyte[] buf;

extern(C) static {
    void _op_lookup(fuse_req_t req, fuse_ino_t parent, char *name) {
        scope(failure) fuse_reply_err(req, EIO);
        (cast(Filesystem)fuse_req_userdata(req)).lookup(req, parent, name);
    }
    void _op_forget(fuse_req_t req, fuse_ino_t ino, uint nlookup) {
        scope(exit) fuse_reply_none(req);
        (cast(Filesystem)fuse_req_userdata(req)).forget(ino, nlookup);
    }
    void _op_getattr(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) {
        scope(failure) fuse_reply_err(req, EIO);
        (cast(Filesystem)fuse_req_userdata(req)).getattr(req, ino, fi);
    }
    void _op_open(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) {
        scope(failure) fuse_reply_err(req, EIO);
        (cast(Filesystem)fuse_req_userdata(req)).open(req, ino, fi);
    }
    void _op_release(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) {
        scope(failure) fuse_reply_err(req, EIO);
        (cast(Filesystem)fuse_req_userdata(req)).release(req, ino, fi);
    }
    void _op_read(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, fuse_file_info *fi) {
        scope(failure) fuse_reply_err(req, EIO);
        (cast(Filesystem)fuse_req_userdata(req)).read(req, ino, size, off, fi);
    }

    fuse_lowlevel_ops ops = {
        lookup:  &_op_lookup,
        forget:  &_op_forget,
        getattr: &_op_getattr,
        open:    &_op_open,
        release: &_op_release,
        read:    &_op_read,
    };
}
public:
    /************************************************************************************
     * Implement ISelectable so that Fuse can be integrated in a select-loop
     ***********************************************************************************/
    Handle fileHandle() {
        return cast(Handle)fuse_chan_fd(chan);
    }
    bool exited() {
        return fuse_session_exited(s) != 0;
    }

    /************************************************************************************
     * Read one instruction on Fuse Socket, and dispatch to handler.
     * Might block on read, you may want to check with a Selector first.
     ***********************************************************************************/
    void dispatch_waiting() {
        fuse_chan tmpch = chan;

        auto res = fuse_chan_recv(&tmpch, buf.ptr, buf.length);

        if (res>0) {
            fuse_session_process(s, buf.ptr, res, tmpch);
        } else if ( exited ) {

            throw new Exception("We're done here");
        }
    }

protected:
    this(char[] mountpoint, char[][] args) {
        this.mountpoint = mountpoint;
        fuse_args f_args = fuse_args.fromD(args);

        chan = fuse_mount((mountpoint~'\0').ptr, &f_args);
        assert(chan, "Failed to mount Filesystem");
        scope(failure)fuse_unmount((mountpoint~'\0').ptr, chan);

        s = fuse_lowlevel_new(&f_args, &ops, ops.sizeof, cast(void*)this);
        scope(failure)fuse_session_destroy(s);

        fuse_session_add_chan(s, chan);

        buf = new ubyte[fuse_chan_bufsize(chan)];
    }
    ~this() {
        if (s)
            fuse_session_destroy(s);
        if (chan)
            fuse_unmount((mountpoint~'\0').ptr, chan);
    }
    abstract void lookup(fuse_req_t req, fuse_ino_t parent, char *name);
    abstract void forget(fuse_ino_t ino, uint nlookup);
    abstract void getattr(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi);
    abstract void open(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi);
    abstract void release(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi);
    abstract void read(fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, fuse_file_info *fi);

public: // IProcessor implementation
    ISelectable[] conduits() {
        return [this];
    }
    void process(ref SelectionKey key) {
        if (exited) {
            // TODO: Trigger termination somehow?
        } else {
            dispatch_waiting();
        }
    }
    Time nextDeadline() { return Time.max; }
    void processTimeouts(Time now) { }
}

debug (FUSETest) {
    import tango.io.Stdout;
    import tango.io.selector.Selector;
    class TestFS: Filesystem {
        this(char[] mnt) {
            super(mnt);
        }
        void lookup(fuse_req_t req, fuse_ino_t parent, char *name) {
            Stdout(req, parent, name).newline;
        }
        void getattr(fuse_req_t req, fuse_ino_t ino, fuse_file_info *fi) {
            if (ino == ROOT_INODE) {
                stat_t s;
                s.st_ino = ino;
                s.st_mode = S_IFDIR | 0775;
                s.st_nlink = 2;
                auto res = fuse_reply_attr(req, &s, 60);
                assert(res == 0);
            } else {
                Stdout("stat: needed", req, ino, fi).newline;
            }
        }
    }
    int main() {
        scope(failure) return -1;
        auto fs = new TestFS("/tmp/tst");
        auto selector = new Selector();
        selector.open(2,2);
        selector.register(fs, Event.Read, null);
        int events;
        while ((events = selector.select())>0) {
            foreach (SelectionKey key; selector.selectedSet())
            {
                if (key.isReadable()) {
                    if (fs.exited) {
                        return -1;
                    } else {
                        fs.dispatch_waiting();
                    }
                }

                if (key.isError() || key.isHangup() || key.isInvalidHandle()) {
                    return -1;
                }
            }
        }
    }
}