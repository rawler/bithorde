/****************************************************************************************
 * Pumping micro-framework for select-driven asynchronous processing.
 *
 * Copyright (C) 2010 Ulrik Mikaelsson <ulrik.mikaelsson@gmail.com>
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
 ****************************************************************************************/
module lib.pumping;

public import tango.io.model.IConduit;
public import tango.io.selector.model.ISelector;

import tango.core.Exception;
import tango.io.device.Device : IODevice = Device;
import tango.io.selector.Selector;
import tango.io.selector.SelectorException;
import tango.net.device.Socket : Socket, Address;
import tango.sys.Common;
import tango.sys.consts.errno;
import tango.time.Clock;
import tango.util.container.HashSet;

import tango.stdc.posix.fcntl;
import tango.stdc.stdlib;
import tango.stdc.string;

/****************************************************************************************
 * Processors are the work-horses of the Pump framework. Each processor tracks
 * their own conduits and timeouts.
 ***************************************************************************************/
interface IProcessor : ISelectable {
    /************************************************************************************
     * Process an event from the pump
     ***********************************************************************************/
    void process(ref SelectionKey cause);

    /************************************************************************************
     * When does this Processor need to process it's next timeout?
     ***********************************************************************************/
    Time nextDeadline();

    /************************************************************************************
     * Let the processor process all it's timeouts expected to happen until now.
     ***********************************************************************************/
    void processTimeouts(Time now);

    /************************************************************************************
     * Close the underlying resources managed by the IProcessor
     ***********************************************************************************/
    void close();
}

version (Posix) {
    import tango.stdc.posix.signal;
    static this() {
        sigignore(SIGPIPE);
    }
}

version (linux) {
    import tango.stdc.posix.unistd;
    extern (C) int eventfd(uint initval, int flags);
    class EventFD : ISelectable {
        int _handle;
        Handle fileHandle() { return cast(Handle)_handle; }
        this() {
            _handle = eventfd(0, 0);
            if (_handle < 0)
                throw new Exception("Error creating eventfd: " ~ SysError.lastMsg, __FILE__, __LINE__);
        }
        ~this() {
            .close (_handle);
        }
        void signal() {
            static ulong add = 1;
            auto written = .write(_handle, &add, add.sizeof);
        }
        void clear() {
            static ulong res;
            .read(_handle, &res, res.sizeof);
        }
    }
} else {
    static assert(0, "Server needs abort-implementation for non-linux OS");
}

class BaseConnection(TYPE: IConduit) : IProcessor {
    class BufferException : Exception {
        this() {
            super("Not enough space to write data");
        }
    }

    /************************************************************************************
     * Needs overriding for handling
     * Returns: the amount of bytes consumed from the buffer
     ***********************************************************************************/
    abstract size_t onData(ubyte[] data);

    /************************************************************************************
     * Should probably be overridden to react on closed connections.
     ***********************************************************************************/
    void onClosed() {}

    /************************************************************************************
     * Will be signalled when the internal buffer is cleared, when the connection is
     * ready to queue more data for sending.
     ***********************************************************************************/
    void onWriteClear() {}

    struct Buffer {
        ubyte[] _data;
        size_t fill;

        void realloc(size_t size) {
            _data = (cast(ubyte*).realloc(_data.ptr, size))[0..size];
        }

        void pop(size_t size) {
            assert(size <= fill);
            fill -= size;
            if (fill > 0)
                memmove(_data.ptr, _data.ptr+size, fill);
        }

        size_t queue(ubyte[] data) in {
            assert(hasRoom(data.length));
        } body {
            auto newFill = fill + data.length;
            this._data[fill..newFill] = data;
            fill = newFill;
            return data.length;
        }

        bool hasRoom(size_t size) {
            return fill+size <= _data.length;
        }

        ubyte[] freeSpace() {
            return _data[fill..$];
        }

        ubyte[] valid() {
            return _data[0..fill];
        }
    }
protected:
    Pump pump;
    ISelectable.Handle selectHandle;
    TYPE conduit;
    Buffer writeBuf, readBuf;
public:
    this(Pump p, TYPE conduit, size_t bufsize) {
        pump = p;
        _setupHandle(conduit);
        selectHandle = conduit.fileHandle;
        this.conduit = conduit;
        writeBuf.realloc(bufsize);
        readBuf.realloc(bufsize);
        pump.registerProcessor(this);
    }

    ~this() {
        writeBuf.realloc(0);
        readBuf.realloc(0);
    }

    private void _setupHandle(ISelectable s) {
        auto handle = s.fileHandle;
        int x = fcntl(handle, F_GETFL, 0);
        x |= O_NONBLOCK;
        if(fcntl(handle, F_SETFL, x) is -1)
           throw new IOException("Unable to set conduit non-blocking: " ~ SysError.lookup(SysError.lastCode));
    }

    /************************************************************************************
     * Tries writing the provided buffer, raising Exception on error, calling close if
     * other side closed connection.
     * Returns: The amount of bytes actually written.
     ***********************************************************************************/
    private size_t _tryWrite(ubyte[] buf) {
        assert(buf.length > 0);
        auto written = .write(fileHandle, buf.ptr, buf.length);
        if (written is -1) {
            auto ecode = SysError.lastCode;
            switch (ecode) {
                case EWOULDBLOCK:
                    return 0;
                default:
                    throw new IOException("Failed to write: " ~ SysError.lookup(ecode));
            }
        } else if (written == 0) {
            close();
        }
        return written;
    }

    private void _dequeue() {
        auto written = _tryWrite(writeBuf.valid);
        if (written) writeBuf.pop(written);
        if (!writeBuf.fill) {
            this.pump.registerProcessor(this, false);
            this.onWriteClear();
        }
    }

    protected void _filterRead(ubyte[]) {};
    private void _readAndPush() {
        int read = conduit.read(readBuf.freeSpace);
        if (read == conduit.Eof) {
            close();
        } else if (read > 0) {
            // TODO: There is currently a race-condition if filter is installed during
            //       onData(), with encrypted data in the buffer.
            //       Needs re-implementation of onData into multi-call signature to
            //       handle properly.
            _filterRead(readBuf._data[readBuf.fill..readBuf.fill+read]);
            readBuf.fill += read;
            auto processed = onData(readBuf.valid());
            readBuf.pop(processed);
        }
    }

    /************************************************************************************
     * Implement IProcessor
     ***********************************************************************************/
    ISelectable.Handle fileHandle() {
        return selectHandle;
    }
    void process(ref SelectionKey cause) {
        if (cause.events & (Event.Error | Event.Hangup)) {
          close();
          return;
        }
        if (cause.events & (Event.Write))
            _dequeue();
        if (cause.events & (Event.Read))
            _readAndPush();
    }

    size_t write(ubyte[] data) in {
        assert(data.length > 0);
    } body {
        if (!writeBuf.hasRoom(data.length))
            return 0;
        if (writeBuf.fill) {
            writeBuf.queue(data);
        } else {
            auto written = _tryWrite(data);
            if (written != data.length) {
                assert(this.pump);
                writeBuf.queue(data[written..$]);
                this.pump.registerProcessor(this, true);
            }
        }
        return data.length;
    }

    void close() {
        if (closed)
            return;
        pump.unregisterProcessor(this);
        conduit.close();
        conduit = null;
        onClosed();
    }

    bool closed() {
        return conduit is null;
    }

    /// Default to no deadlines. Subclasses may override
    Time nextDeadline() { return Time.max; } 
    void processTimeouts(Time now) {}
}

/****************************************************************************************
 * Connection-type supporting installing read and write-filters.
 * @note: Filters must for the moment be symmetrical such that inlength = outlength.
 *        I.E. stream-ciphers work, but compression or block ciphers don't.
 * @note: Filters may change data in-place such that the input and output-blocks
 *        overlap. Therefore, arguments to write() may not make the assumption that data
 *        is intact afterwards.
 ***************************************************************************************/
class FilteredConnection(TYPE) : BaseConnection!(TYPE) {
    alias size_t delegate(void[], void[]) Filter;
    private Filter _readFilter = null, _writeFilter = null;

    /************************************************************************************
     * Instantiate the filtered connection. Note the need to install filters using
     * set(Read|Write)Filter() after instantiation. This since both ends might want to
     * exchange filter parameters in the clear first.
     ***********************************************************************************/
    this(Pump p, Socket socket, size_t bufsize) {
        super(p, socket, bufsize);
    }

    /************************************************************************************
     * Install filters used for the connection.
     * @note: Implementation currently has a weakness handling data already buffered
     *        when filters are installed. Mainly a problem in the read-buffer, where the
     *        other side may have sent filter-parameters at the same time as first
     *        filtered messages.
     ***********************************************************************************/
    void readFilter(Filter f) {
        _readFilter = f;
    }
    /// Ditto
    void writeFilter(Filter f) {
        _writeFilter = f;
    }

    /************************************************************************************
     * Write data, but pass it through the filter before passing it to network buffers.
     * @note: Since data may be modified in-place, data must be mutable, and considered
     *        wasted after this function returns.
     ***********************************************************************************/
    size_t write(ubyte[] data) {
        if (_writeFilter) {
            auto processed = _writeFilter(data, data);
            assert(processed == data.length);
        }
        return super.write(data);
    }

    /************************************************************************************
     * Override the _filterRead-hook in BaseConnection.
     ***********************************************************************************/
    protected void _filterRead(ubyte[] data) {
        if (_readFilter) {
            auto processed = _readFilter(data, data);
            assert(processed == data.length);
        }
    }
}

/****************************************************************************************
 * Base Socket-Connection declared for convenience.
 ***************************************************************************************/
class BaseSocket : BaseConnection!(Socket) {
    this(Pump p, Socket socket, size_t bufsize) {
        super(p, socket, bufsize);
    }

    Address remoteAddress() {
        return conduit.native.remoteAddress;
    }
}

/****************************************************************************************
 * Base Socket-FilteredConnection declared for convenience.
 ***************************************************************************************/
class FilteredSocket : FilteredConnection!(Socket) {
    this(Pump p, Socket socket, size_t bufsize) {
        super(p, socket, bufsize);
    }

    Address remoteAddress() {
        return conduit.native.remoteAddress;
    }
}

/****************************************************************************************
 * Implements a Server-template for Pumpable, acception connections and creating new
 * CONNECTION instances for incoming connections.
 ***************************************************************************************/
class BaseSocketServer(T,C=BaseSocket) : IProcessor {
    abstract C onConnection(Socket s);
    void onClosed() {};

private:
    ISelectable.Handle selectHandle;
    T serverSocket;
protected:
    Pump pump;
public:
    this(Pump p, T serverSocket) {
        this.pump = p;
        this.serverSocket = serverSocket;
        selectHandle = serverSocket.fileHandle;
        pump.registerProcessor(this);
    }

    void close() {
        serverSocket.close();
        onClosed();
    }

    /************************************************************************************
     * Implement IProcessor
     ***********************************************************************************/
    ISelectable.Handle fileHandle() {
        return selectHandle;
    }
    void process(ref SelectionKey cause) {
        assert(cause.events & Event.Read);
        auto newSock = this.serverSocket.accept();
        auto newConnection = onConnection(newSock);
    }
    Time nextDeadline() { return Time.max; } // IGNORED
    void processTimeouts(Time now) {} // IGNORED
}

/****************************************************************************************
 * Pump is the core of the Pump framework. The pump manages all the Processors,
 * selects among incoming events, and triggers process-events.
 ***************************************************************************************/
class Pump {
private:
    ISelector selector;
    HashSet!(IProcessor) processors;
    EventFD evfd;               /// Used for sending events breaking select
    bool closed;
public:
    /************************************************************************************
     * Create a Pump with a possible initial list of processors
     ***********************************************************************************/
    this(IProcessor[] processors=[], uint sizeHint=0) {
        this.selector = new Selector;
        if (!sizeHint) sizeHint = processors.length ? processors.length : 8;
        selector.open(sizeHint, sizeHint * 2);
        this.processors = new typeof(this.processors);

        // Setup eventFD
        this.evfd = new EventFD;
        this.selector.register(evfd, Event.Read);

        foreach (p; processors)
            registerProcessor(p);
    }

    /************************************************************************************
     * Check if processor is registered in this pump
     ***********************************************************************************/
    bool has(IProcessor p) {
        foreach (x; processors) {
            if (x is p)
                return true;
        }
        return false;
    }

    /************************************************************************************
     * Register a conduit to a processor. The Processor may or may not be registered in
     * this pump before.
     ***********************************************************************************/
    void registerProcessor(IProcessor p, bool write = false) {
        processors.add(p);
        auto mask = write ? Event.Read | Event.Write : Event.Read;
        selector.register(p, mask, cast(Object)p);
    }

    /************************************************************************************
     * Unregister a conduit from this processor.
     ***********************************************************************************/
    void unregisterProcessor(IProcessor c) {
        if (!closed)
            selector.unregister(c);
        processors.remove(c);
    }

    /************************************************************************************
     * Shuts down this pump, stops the main loop and frees resources.
     ***********************************************************************************/
    void close() {
        closed = true;
        evfd.signal();
    }

    /************************************************************************************
     * Run until closed
     ***********************************************************************************/
    void run() {
        scope(exit) cleanup;
        try while (!closed) {
            Time nextDeadline = Time.max;
            foreach (p; processors) {
                auto t = p.nextDeadline;
                if (t < nextDeadline)
                    nextDeadline = t;
            }
            auto timeout = nextDeadline-Clock.now;
            if ((timeout > TimeSpan.zero) && (selector.select(timeout)>0)) {
                foreach (SelectionKey key; selector.selectedSet()) {
                    auto processor = cast(IProcessor)key.attachment;
                    if (processor)
                        processor.process(key);
                }
            }
            auto now = Clock.now;
            foreach (p; processors)
                p.processTimeouts(now);
        } catch (SelectorException e) {
            // Ignore thrown SelectException during shutdown, due to Tango ticket #2025
            if (!closed)
                throw e;
        }
    }

    private void cleanup() {
        foreach (p; processors)
            p.close();
        selector.close;
    }
}

debug(UnitTest) {
    import tango.core.Thread;
    import tango.core.sync.Mutex;
    import tango.io.Path : FS;
    import tango.io.Stdout;
    import tango.net.device.LocalSocket;

    class ServerTest : BaseSocketServer!(LocalServerSocket, FilteredSocket) {
        FilteredSocket.Filter writeFilter, readFilter;
        this(Pump p, LocalServerSocket s) { super(p,s); }
        void delegate() whenDone;
        FilteredSocket onConnection(Socket s) {
            auto c = new ServerConnection(pump, s, this);
            c.readFilter = readFilter;
            c.writeFilter = writeFilter;
            return c;
        }
        void onClosed() {
            whenDone();
        }
    }
    class ServerConnection : FilteredSocket {
        ServerTest server;
        this(Pump p, Socket s, ServerTest server) {
            super(p, s, 4096);
            this.server = server;
        }
        size_t onData(ubyte[] data) {
            assert(data == cast(ubyte[])x"1122334455" || data == cast(ubyte[])x"66778899");
            write(data[0..3]);
            write(data[3..$]);
            return data.length;
        }
        void onClosed() {
            server.close();
        }
    }
    class ClientTest : FilteredSocket {
        ubyte[] lastRecieved;
        this(Pump p, Socket s) { super(p, s, 4096); }
        size_t onData(ubyte[] data) {
            if (data[0..4] == cast(ubyte[])x"11223344") {
                write(cast(ubyte[])x"66778899".dup);
                return 4;
            } else {
                lastRecieved = data;
                close();
                return data.length;
            }
        }
    }

    unittest {
        const SOCKET = "/tmp/pumpingtest";
        auto pump = new Pump;

        FS.remove(SOCKET);
        scope(exit) FS.remove(SOCKET);
        auto serverSocket = new LocalServerSocket(SOCKET);
        auto server = new ServerTest(pump, serverSocket);
        server.whenDone = &pump.close;

        auto clientSocket = new LocalSocket(SOCKET);
        auto client = new ClientTest(pump, clientSocket);

        client.write(cast(ubyte[])x"1122334455".dup);

        pump.run();
        assert(client.lastRecieved == cast(ubyte[])x"5566778899");
        Stderr("Pumping.UnitTest-plain: SUCCESS").newline;
    }

    unittest {
        size_t filter(void[] input_, void[] output_) {
            auto input = cast(ubyte[])input_;
            auto output = cast(ubyte[])output_;
            ubyte key = 0xAA;
            foreach (i,b; input)
                output[i] = b ^ key;
            return input.length;
        }
        const SOCKET = "/tmp/pumpingtest";
        auto pump = new Pump;

        FS.remove(SOCKET);
        scope(exit) FS.remove(SOCKET);
        auto serverSocket = new LocalServerSocket(SOCKET);
        auto server = new ServerTest(pump, serverSocket);
        server.writeFilter = server.readFilter = &filter;
        server.whenDone = &pump.close;

        auto clientSocket = new LocalSocket(SOCKET);
        auto client = new ClientTest(pump, clientSocket);
        client.readFilter = &filter;
        client.writeFilter = &filter;

        client.write(cast(ubyte[])x"1122334455".dup);

        pump.run();
        assert(client.lastRecieved == cast(ubyte[])x"5566778899");
        Stderr("Pumping.UnitTest-crypto: SUCCESS").newline;
    }

}
