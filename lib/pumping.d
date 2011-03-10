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
import tango.net.device.Socket : Socket;
import tango.sys.Common;
import tango.sys.consts.errno;
import tango.time.Clock;

import tango.stdc.posix.fcntl;
import tango.stdc.stdlib;
import tango.stdc.string;

/****************************************************************************************
 * Processors are the work-horses of the Pump framework. Each processor tracks
 * their own conduits and timeouts.
 ***************************************************************************************/
interface IProcessor {
    /************************************************************************************
     * Which Conduits can trigger events for this IProcessor?
     ***********************************************************************************/
    ISelectable[] conduits();

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
     * Enslaved to a pump
     ***********************************************************************************/
    void onBound(Pump pump);
}

class BaseConnection : IProcessor {
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
    void onClosed() {};

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

        void queue(ubyte[] data) in {
            assert(hasRoom(data.length));
        } body {
            auto newFill = fill + data.length;
            this._data[fill..newFill] = data;
            fill = newFill;
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
private:
    Pump pump;
    ISelectable[1] selectHandle;
    IConduit conduit;
    Buffer writeBuf, readBuf;
public:
    this(IODevice device, size_t bufsize) {
        _setupHandle(device);
        selectHandle[0] = device;
        conduit = device;
        writeBuf.realloc(bufsize);
        readBuf.realloc(bufsize);
    }

    this(Socket socket, size_t bufsize) {
        _setupHandle(socket);
        selectHandle[0] = socket;
        conduit = socket;
        writeBuf.realloc(bufsize);
        readBuf.realloc(bufsize);
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
        auto written = posix.write(selectHandle[0].fileHandle, buf.ptr, buf.length);
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
        if (!writeBuf.fill)
            this.pump.registerConduit(selectHandle[0], this, false);
    }

    /************************************************************************************
     * Implement IProcessor
     ***********************************************************************************/
    ISelectable[] conduits() {
        return selectHandle;
    }
    void process(ref SelectionKey cause) {
        if (cause.events & (Event.Error | Event.Hangup)) {
          close();
          return;
        }
        if (cause.events & (Event.Write)) {
            _dequeue();
        }
        if (cause.events & (Event.Read)) {
            int read = conduit.read(readBuf.freeSpace);
            assert(read >= 0);
            if (read == 0) {
                close();
            } else {
                readBuf.fill += read;
                auto processed = onData(readBuf.valid());
                readBuf.pop(processed);
            }
        }
    }
    void onBound(Pump pump) {
        this.pump = pump;
    }

    void write(ubyte[] data) {
        if (!writeBuf.hasRoom(data.length))
            throw new IOException("Not enough bufferspace to write");
        if (writeBuf.fill)
            return writeBuf.queue(data);

        auto written = _tryWrite(data);
        if (written != data.length) {
            assert(this.pump);
            this.pump.registerConduit(this.selectHandle[0], this, true);
            return writeBuf.queue(data[written..$]);
        }
    }

    void close() {
        conduit.close();
        onClosed();
    }

    /// Default to no deadlines. Subclasses may override
    Time nextDeadline() { return Time.max; } 
    void processTimeouts(Time now) {}
}

/****************************************************************************************
 * Implements a Server-template for Pumpable, acception connections and creating new
 * CONNECTION instances for incoming connections.
 ***************************************************************************************/
class BaseSocketServer(T) : IProcessor {
    abstract BaseConnection onConnection(Socket s);
    void onClosed() {};

private:
    Pump pump;
    ISelectable[1] selectHandle;
    T serverSocket;
public:
    this(T serverSocket) {
        selectHandle[0] = this.serverSocket = serverSocket;
    }

    void close() {
        serverSocket.close();
        onClosed();
    }

    /************************************************************************************
     * Implement IProcessor
     ***********************************************************************************/
    ISelectable[] conduits() {
        return selectHandle;
    }
    void process(ref SelectionKey cause) {
        assert(cause.events & Event.Read);
        auto newSock = this.serverSocket.accept();
        auto newConnection = onConnection(newSock);
        pump.registerConduit(newSock, newConnection);
    }
    void onBound(Pump pump) {
        this.pump = pump;
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
    IProcessor[] processors;
public:
    /************************************************************************************
     * Create a Pump with a possible initial list of processors
     ***********************************************************************************/
    this(IProcessor[] processors=[], uint sizeHint=0) {
        selector = new Selector;
        if (!sizeHint) sizeHint = processors.length ? processors.length : 8;
        selector.open(sizeHint, sizeHint * 2);
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
    void registerConduit(ISelectable c, IProcessor p, bool write = false) {
        if (!has(p))
            processors ~= p;
        auto mask = write ? Event.Read | Event.Write : Event.Read;
        selector.register(c, mask, cast(Object)p);
        p.onBound(this);
    }

    /************************************************************************************
     * Unregister a conduit from this processor.
     ***********************************************************************************/
    void unregisterConduit(ISelectable c) {
        selector.unregister(c);
    }

    /************************************************************************************
     * Register an IProcessor in this pump, including all it's conduits.
     ***********************************************************************************/
    void registerProcessor(IProcessor p) {
        foreach (c; p.conduits)
            registerConduit(c, p);
        p.onBound(this);
    }

    /************************************************************************************
     * Shuts down this pump, stops the main loop and frees resources.
     ***********************************************************************************/
    void close() {
        auto s = selector;
        selector = null;
        s.close;
    }

    /************************************************************************************
     * Run until closed
     ***********************************************************************************/
    void run() {
        try while (selector) {
            Time nextDeadline = Time.max;
            foreach (p; processors) {
                auto t = p.nextDeadline;
                if (t < nextDeadline)
                    nextDeadline = t;
            }
            ISelectable[] toRemove;
            auto timeout = nextDeadline-Clock.now;
            if ((timeout > TimeSpan.zero) && (selector.select(timeout)>0)) {
                foreach (SelectionKey key; selector.selectedSet())
                {
                    auto processor = cast(IProcessor)key.attachment;
                    processor.process(key);
                    if (key.isError() || key.isHangup() || key.isInvalidHandle()) {
                        toRemove ~= key.conduit; // Delayed removal to not break traversal
                    }
                }
//                foreach (c; toRemove) unregisterConduit(c);
            }
            auto now = Clock.now;
            foreach (p; processors)
                p.processTimeouts(now);
        } catch (SelectorException e) {
            // Ignore thrown SelectException during shutdown, due to Tango ticket #2025
            if (selector)
                throw e;
        }
    }
}

debug(UnitTest) {
    import tango.net.device.LocalSocket;
    import tango.io.Stdout;

    class ServerTest : BaseSocketServer!(LocalServerSocket) {
        this(LocalServerSocket s) { super(s); }
        void delegate() whenDone;
        BaseConnection onConnection(Socket s) {
            return new ServerConnection(s, this);
        }
        void onClosed() {
            whenDone();
        }
    }
    class ServerConnection : BaseConnection {
        ServerTest server;
        this(Socket s, ServerTest server) {
            super(s, 4096);
            this.server = server;
        }
        size_t onData(ubyte[] data) {
            write(data[0..4]);
            write(data[4..$]);
            return data.length;
        }
        void onClosed() {
            server.close();
        }
    }
    class ClientTest : BaseConnection {
        this(Socket s) { super(s, 4096); }
        size_t onData(ubyte[] data) {
            if (data[0..4] == cast(ubyte[])x"11223344") {
                write(cast(ubyte[])x"66778899");
                return 4;
            } else {
                assert(data == cast(ubyte[])x"5566778899");
                close();
                return data.length;
            }
        }
    }

    unittest {
        auto pump = new Pump;

        auto serverSocket = new LocalServerSocket("/tmp/pumpingtest");
        auto server = new ServerTest(serverSocket);
        server.whenDone = &pump.close;
        pump.registerProcessor(server);

        auto clientSocket = new LocalSocket("/tmp/pumpingtest");
        auto client = new ClientTest(clientSocket);
        pump.registerProcessor(client);

        client.write(cast(ubyte[])x"1122334455");

        pump.run();
    }
}
