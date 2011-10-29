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
module tests.bithordelib;

private import tango.core.Thread;
private import tango.core.sync.Mutex;
private import tango.core.sync.Semaphore;
private import tango.core.tools.TraceExceptions;
private import tango.io.Console;
private import tango.io.FilePath;
private import tango.io.selector.model.ISelector;
private import tango.io.Stdout;
private import tango.net.device.LocalSocket;
private import tango.net.device.Socket;
private import tango.net.InternetAddress;
private import tango.text.Arguments;
private import tango.text.convert.Integer;
private import tango.time.Clock;
private import tango.util.log.AppendConsole;
private import tango.util.log.LayoutDate;
private import tango.util.log.Log;

import daemon.server;
import daemon.config;
import daemon.routing.friend;

import lib.client;
import lib.connection;
import lib.hashes;
import lib.message;
import lib.pumping;

/****************************************************************************************
 * A stepping-server is a test-mockup allowing us to drive a server one request at a time
 ***************************************************************************************/
class SteppingServer : Server {
    Thread thread;
    Semaphore sem;
    Mutex m;
    SteppingConnection[] connections;

    /************************************************************************************
     * A connection that can be halted and processed, one message at a time.
     ***********************************************************************************/
    class SteppingConnection : Connection {
        ProcessCallback realMessageHandler;

        this(Pump p, Socket s) {
            connections ~= this;
            super(p, s);
        }

        private void _proxyMessageHandler(Connection c, message.Type t, ubyte[] buf) {
            synchronized (this.outer) sem.wait();
            return realMessageHandler(c, t, buf);
        }
        ProcessCallback messageHandler(ProcessCallback h) {
            super.messageHandler(&_proxyMessageHandler);
            return realMessageHandler = h;
        }
    }

    /************************************************************************************
     * Fork new server in separate thread.
     ***********************************************************************************/
    static SteppingServer launch(char[] name, ushort port, Server[] friends=[]) {
        auto parent = Thread.getThis;
        auto newName = "S_"~name;
        auto oldName = parent.name; // Temporarily overwrite name of current thread, to make pretty logs.
        parent.name = newName;
        auto s = new SteppingServer(name, port, friends);
        auto thread = s.thread = new Thread(&s.run);
        thread.name = newName;
        thread.isDaemon = true;
        thread.start();
        parent.name = oldName;
        return s;
    }

    private this(char[] name, ushort port, Server[] friends=[]) {
        auto c = new Config;
        c.name = "TestServer-"~name;
        c.port = port;
        c.unixSocket = "/tmp/bithorde-test-"~name;
        c.cachedir = new FilePath("cache-test-"~name);
        if (!c.cachedir.exists)
            c.cachedir.createFolder();
        foreach (srv; friends) {
            auto f = new Friend(srv.name);
            f.addr = "localhost";
            f.port = srv.config.port;
            c.friends[srv.name] = f;
        }

        m = new Mutex(this);
        sem = new Semaphore();

        super(c, new Arguments);
    }

    /************************************************************************************
     * _createConnection overridden with SteppingConnection
     ***********************************************************************************/
    Connection _createConnection(Socket s) {
        return new SteppingConnection(pump, s);
    }

    void step(int steps=1) {
        for (;steps>0; steps--)
            sem.notify();
    }

    void reset(uint steps=0) {
        while (!m.tryLock) {
            sem.notify();
        }
        scope(exit) m.unlock();
        auto oldSem = sem;
        volatile sem = new Semaphore(steps);
        oldSem.notify();
    }

    void shutdown() {
        reset(1000);
        super.shutdown();
    }
}

/****************************************************************************************
 * Helper to setup a client connected to a server.
 ***************************************************************************************/
SimpleClient createClient(SteppingServer s, char[] name="libtest") {
    Thread.sleep(0.1); // Ensure server has time to get up
    LOG.info("Opening Client...");
    auto retval = new SimpleClient(new LocalAddress(s.config.unixSocket), name);
    Thread.sleep(0.1); // Ensure first request is not merged with handshake, for server-stepping to work.
    return retval;
}

/*----------------------- Actual tests begin here -------------------------------------*/

/****************************************************************************************
 * Verifies that the bithorde lib times out stale requests correctly.
 ***************************************************************************************/
void testLibTimeout(SteppingServer s) {
    s.reset();
    LOG.info("Client open, sending assetRequest");
    auto client = createClient(s);
    auto ids = [new Identifier(message.HashType.SHA1, cast(ubyte[])x"c1531277498f21cb9ded5741f7a0d66c66505bca")];
    bool gotTimeout = false;
    client.open(ids, delegate(IAsset asset, Status status, AssetStatus resp) {
        assert(asset, "Asset is null");
        if (status == Status.TIMEOUT) {
            LOG.info("SUCCESS: Timeout gotten");
            client.close();
        } else {
            assert(false, "Expected Timeout but got other status " ~ statusToString(status));
        }
        assert(!resp, "Got unexpected response");
    }, TimeSpan.fromMillis(500));
    LOG.info("Request sent, expecting Timeout");
    client.run();
    s.step(2);
}

/****************************************************************************************
 * Verifies that the bithorde server times out stale forwarded requests correctly.
 ***************************************************************************************/
void testServerTimeout(SteppingServer src, SteppingServer proxy) {
    src.reset(0);
    proxy.reset(100);
    Thread.sleep(0.2);
    auto client = createClient(proxy);
    LOG.info("Client open, sending assetRequest");
    auto ids = [new Identifier(message.HashType.SHA1, cast(ubyte[])x"c1531277498f21cb9ded5741f7a0d66c66505bca")];
    bool gotTimeout = false;
    auto sendTime = Clock.now;
    client.open(ids, delegate(IAsset asset, Status status, AssetStatus resp) {
        assert(asset, "Asset is null");
        assert(resp !is null, "Did not get expected response-message");
        auto elapsed = Clock.now - sendTime;
        assert(elapsed.millis > 300, "Too little time has passed. Can't be result of Timeout.");
        if (status == Status.NOTFOUND) {
            gotTimeout = true;
            client.close();
        } else {
            assert(false, "Expected NOTFOUND but got other status " ~ statusToString(status));
        }
    }, TimeSpan.fromMillis(1000));
    LOG.info("Request sent, expecting Timeout");
    client.run();
    if (gotTimeout)
        LOG.info("SUCCESS: NOTFOUND after Timeout");
    else
        assert(false, "Did not get timeout");
}

/****************************************************************************************
 * Tests uploading an asset
 ***************************************************************************************/
Identifier[] testAssetUpload(SteppingServer dst) {
    Identifier[] retVal;

    const char[] testData = "ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvz";
    const int times = 5;
    dst.step(100);
    Thread.sleep(0.1);
    auto client = createClient(dst);
    LOG.info("Client open, uploading asset");
    auto expectedStatus = Status.SUCCESS;
    void onAssetStatus(IAsset _asset, Status status, AssetStatus resp) {
        auto asset = cast(RemoteAsset)_asset;
        LOG.trace("status: {}", message.statusToString(status));
        assert(asset && (status == expectedStatus));

        if (resp && (status == Status.SUCCESS)) {
            if (resp.idsIsSet) { // Upload Complete, got response
                retVal = asset.ids;
                LOG.info("SUCCESS! Assetid is", formatMagnet(asset.ids, 0));
                expectedStatus = Status.INVALID_HANDLE;
                client.close();
            } else { // Initial "ok to upload"-response
                for (int i = 0; i < times; i++)
                    asset.sendDataSegment(i*testData.length,cast(ubyte[])testData);
            }
        }
    }
    client.beginUpload(testData.length*times, &onAssetStatus);
    LOG.info("Request sent, expecting Timeout");
    client.run();

    return retVal;
}

/****************************************************************************************
 * Tests fetching an asset with timeouts. Verifies that bithordelib handles retrying on
 * timeouts.
 ***************************************************************************************/
void testAssetFetchWithTimeout(SteppingServer src, Identifier[] ids) {
    const chunkSize = 5;

    src.reset(3);

    auto client = createClient(src);
    LOG.info("Client open, trying to open asset");

    uint pos;
    RemoteAsset asset;

    void gotResponse(Status status, ReadRequest req, ReadResponse resp) {
        assert(status == Status.SUCCESS, "Read should have succeded, but got status " ~ statusToString(status));
        pos += chunkSize;
        if (pos < asset.size)
            asset.aSyncRead(pos, chunkSize, &gotResponse);
        else {
            LOG.info("SUCCESS: Got asset despite timeout");
            client.close();
        }
    }

    client.open(ids, delegate(IAsset _asset, Status status, AssetStatus resp) {
        asset = cast(RemoteAsset)_asset;
        assert(asset && (status == Status.SUCCESS), "Failed opening");

        asset.aSyncRead(pos, chunkSize, &gotResponse, 2, TimeSpan.fromMillis(500));
    });
    auto t = new Thread(delegate() { // After 1 second, let the server respond
        Thread.sleep(1);
        src.step(1000);
    });
    t.isDaemon = true;
    t.start();
    client.run();
}

/****************************************************************************************
 * Tests restarting a partial asset from a restarted server.
 ***************************************************************************************/
void testRestartWithPartialAsset(SteppingServer src, Identifier[] ids) {
    const chunkSize = 5;
    src.reset(1000);

    auto proxy = SteppingServer.launch("RestartProxy", 23416, [src]);
    scope (exit) {
        proxy.reset(1000);
        proxy.shutdown();
    }
    proxy.reset(1000);
    auto client = createClient(proxy);
    LOG.info("Client open, trying to open asset");

    uint pos;
    RemoteAsset asset;

    void gotResponse1(Status status, ReadRequest req, ReadResponse resp) {
        assert(status == Status.SUCCESS, "First-Read should have succeded, but got status " ~ statusToString(status));
        client.close();
    }
    client.open(ids, delegate(IAsset _asset, Status status, AssetStatus resp) {
        asset = cast(RemoteAsset)_asset;
        assert(asset && (status == Status.SUCCESS), "Failed opening, status is " ~ statusToString(status));

        asset.aSyncRead(0, chunkSize, &gotResponse1, 2, TimeSpan.fromMillis(500));
    });
    client.run();
    LOG.info("Shutting down server");
    proxy.shutdown();
    LOG.info("Restarting server");
    proxy = SteppingServer.launch("RestartProxy", 23416, [src]);
    proxy.reset(1000);
    LOG.info("Reconnecting client");
    client = createClient(proxy);

    void gotResponse2(Status status, ReadRequest req, ReadResponse resp) {
        assert(status == Status.SUCCESS, "Read should have succeded, but got status " ~ statusToString(status));
        pos += chunkSize;
        if (pos < asset.size)
            asset.aSyncRead(pos, chunkSize, &gotResponse2);
        else {
            LOG.info("SUCCESS: Got asset even after restart timeout");
            client.close();
        }
    }
    LOG.info("Retrying fetch");
    client.open(ids, delegate(IAsset _asset, Status status, AssetStatus resp) {
        asset = cast(RemoteAsset)_asset;
        assert(asset && (status == Status.SUCCESS), "Failed opening, status is "~statusToString(status));

        asset.aSyncRead(pos, chunkSize, &gotResponse2, 2, TimeSpan.fromMillis(500));
    });
    client.run();
}

/****************************************************************************************
 * Tests restarting a partial asset from a restarted server.
 ***************************************************************************************/
void testSourceGone(SteppingServer src, SteppingServer proxy, Identifier[] ids) {
    const chunkSize = 5;
    src.reset(1000);
    proxy.reset(1000);

    scope client = createClient(proxy);
    LOG.info("Client open, trying to open asset");

    uint pos;
    RemoteAsset asset;
    bool gotNewStatus;
    uint origAvailable;

    void readResponse(Status status, ReadRequest req, ReadResponse resp) {
        assert(status == Status.SUCCESS, "First-Read should have succeded, but got status " ~ statusToString(status));
        if (src) {
            LOG.info("Shutting down source");
            src.shutdown();
            src = null;
        }
    }
    void updateStatus(IAsset _asset, Status status, AssetStatus resp) {
        assert(_asset && (status == Status.SUCCESS), "Status update got non-SUCCESS: " ~ statusToString(status));
        assert(resp.availabilityIsSet, "Availability wasn't set on statusUpdate");
        LOG.trace("Avail: {} {}", resp.availability, origAvailable);
        assert(resp.availability < origAvailable, "Availability wasn't decreased after src-shutdown.");
        LOG.info("SUCCESS: Got status update after source-shutdown.");
        gotNewStatus = true;
        client.close();
    }

    client.open(ids, delegate(IAsset _asset, Status status, AssetStatus resp) {
        asset = cast(RemoteAsset)_asset;
        assert(asset && (status == Status.SUCCESS), "Failed opening, status is " ~ statusToString(status));
        assert(resp.availabilityIsSet, "Availability wasn't set on open");
        origAvailable = resp.availability;
        asset.attachWatcher(&updateStatus);

        asset.aSyncRead(0, chunkSize, &readResponse, 2, TimeSpan.fromMillis(500));
    });
    client.run();
    assert(gotNewStatus, "Did not get status update");
    LOG.info("testSourceGone successful");
}


/*----------------------- Actual tests begin here -------------------------------------*/

/// Log for all the tests
static Logger LOG;

public class MyLayout : Appender.Layout {
    private import tango.text.convert.TimeStamp : format8601;
    private import  tango.text.convert.Format;
    void format (LogEvent event, size_t delegate(void[]) dg) {
        auto thread = Thread.getThis;
        char[32] timebuf;
        auto time = format8601(timebuf, event.time);
        char[128] preamblebuf;
        if (thread.name) dg(Format.sprint(preamblebuf, "{} @{} {} [{}] - ", time, thread.name, event.levelName, event.name));
        else             dg(Format.sprint(preamblebuf, "{} @{} {} [{}] - ", time, cast(void*)thread, event.levelName, event.name));
        dg(event.toString);
    }
}

/// Execute all the tests in order
void main() {
    Log.root.add(new AppendConsole(new MyLayout));
    LOG = Log.lookup("libtest");
    Thread.getThis.name = "client";

    synchronized (Cerr.stream) { Stderr("\nTesting ClientTimeout\n=====================\n").newline; }
    auto src = SteppingServer.launch("Src", 23412);
    scope(exit) src.shutdown();
    testLibTimeout(src);

    synchronized (Cerr.stream) { Stderr("\nTesting ServerTimeout\n=====================\n").newline; }
    auto proxy = SteppingServer.launch("Proxy", 23415, [src]);
    scope(exit) proxy.shutdown();
    testServerTimeout(src, proxy);

    synchronized (Cerr.stream) { Stderr("\nTesting AssetUpload\n===================\n").newline; }
    auto ids = testAssetUpload(src);

    synchronized (Cerr.stream) { Stderr("\nTesting Asset Fetching With Retry on Timeouts\n=============================================\n").newline; }
    testAssetFetchWithTimeout(src, ids);

    synchronized (Cerr.stream) { Stderr("\nTesting Restarting During Partial Asset\n=======================================\n").newline; }
    testRestartWithPartialAsset(src, ids);

    synchronized (Cerr.stream) { Stderr("\nTesting Dropping Source\n=======================================\n").newline; }
    auto node3 = SteppingServer.launch("Node3", 23417, [src, proxy]);
    scope(exit) node3.shutdown();
    testSourceGone(src, node3, ids);

    LOG.info("SUCCESS: All tests done");
}