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
    ISelectable.Handle selectHandle;
    IConduit conduit;
    Buffer writeBuf, readBuf;
public:
    this(Pump p, IODevice device, size_t bufsize) {
        pump = p;
        _setupHandle(device);
        selectHandle = device.fileHandle;
        conduit = device;
        writeBuf.realloc(bufsize);
        readBuf.realloc(bufsize);
        pump.registerProcessor(this);
    }

    this(Pump p, Socket socket, size_t bufsize) {
        pump = p;
        _setupHandle(socket);
        selectHandle = socket.fileHandle;
        conduit = socket;
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
        auto written = posix.write(fileHandle, buf.ptr, buf.length);
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
            this.pump.registerProcessor(this, false);
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

    void write(ubyte[] data) {
        if (!data.length)
            return;
        if (!writeBuf.hasRoom(data.length))
            throw new IOException("Not enough bufferspace to write");
        if (writeBuf.fill)
            return writeBuf.queue(data);

        auto written = _tryWrite(data);
        if (written != data.length) {
            assert(this.pump);
            this.pump.registerProcessor(this, true);
            return writeBuf.queue(data[written..$]);
        }
    }

    void close() {
        pump.unregisterProcessor(this);
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
        pump.registerProcessor(newConnection);
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
public:
    /************************************************************************************
     * Create a Pump with a possible initial list of processors
     ***********************************************************************************/
    this(IProcessor[] processors=[], uint sizeHint=0) {
        selector = new Selector;
        if (!sizeHint) sizeHint = processors.length ? processors.length : 8;
        selector.open(sizeHint, sizeHint * 2);
        this.processors = new typeof(this.processors);
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
        if (selector)
            selector.unregister(c);
        processors.remove(c);
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
            IProcessor[] toRemove;
            auto timeout = nextDeadline-Clock.now;
            if ((timeout > TimeSpan.zero) && (selector.select(timeout)>0)) {
                foreach (SelectionKey key; selector.selectedSet())
                {
                    auto processor = cast(IProcessor)key.attachment;
                    processor.process(key);
                    if (key.isError() || key.isHangup() || key.isInvalidHandle()) {
                        toRemove ~= processor; // Delayed removal to not break traversal
                    }
                }
                foreach (c; toRemove) unregisterProcessor(c);
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
        this(Pump p, LocalServerSocket s) { super(p,s); }
        void delegate() whenDone;
        BaseConnection onConnection(Socket s) {
            return new ServerConnection(pump, s, this);
        }
        void onClosed() {
            whenDone();
        }
    }
    class ServerConnection : BaseConnection {
        ServerTest server;
        this(Pump p, Socket s, ServerTest server) {
            super(p, s, 4096);
            this.server = server;
        }
        size_t onData(ubyte[] data) {
            write(data[0..3]);
            write(data[3..$]);
            return data.length;
        }
        void onClosed() {
            server.close();
        }
    }
    class ClientTest : BaseConnection {
        ubyte[] lastRecieved;
        this(Pump p, Socket s) { super(p, s, 4096); }
        size_t onData(ubyte[] data) {
            if (data[0..4] == cast(ubyte[])x"11223344") {
                write(cast(ubyte[])x"66778899");
                return 4;
            } else {
                lastRecieved = data;
                close();
                return data.length;
            }
        }
    }

    unittest {
        auto pump = new Pump;

        auto serverSocket = new LocalServerSocket("/tmp/pumpingtest");
        auto server = new ServerTest(pump, serverSocket);
        server.whenDone = &pump.close;

        auto clientSocket = new LocalSocket("/tmp/pumpingtest");
        auto client = new ClientTest(pump, clientSocket);

        client.write(cast(ubyte[])x"1122334455");

        pump.run();
        assert(client.lastRecieved == cast(ubyte[])x"5566778899");
        Stderr("Pumping.UnitTest: SUCCESS").newline;
    }
}
