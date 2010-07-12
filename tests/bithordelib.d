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
module tests.libbithorde;

private import tango.core.Thread;
private import tango.core.sync.Semaphore;
private import tango.core.tools.TraceExceptions;
private import tango.io.FilePath;
private import tango.io.selector.model.ISelector;
private import tango.io.Stdout;
private import tango.net.device.LocalSocket;
private import tango.net.device.Socket;
private import tango.net.InternetAddress;
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
import lib.message;

/****************************************************************************************
 * A stepping-server is a test-mockup allowing us to drive a server one request at a time
 ***************************************************************************************/
class SteppingServer : Server {
    Semaphore sem;
    Thread thread;

    this(char[] name, ushort port, Server[] friends=[]) {
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

        sem = new Semaphore;
        super(c);

        thread = new Thread(&run);
        thread.isDaemon = true;
        thread.start();
    }

    bool _processMessageQueue(Connection c) {
        Semaphore oldSem;
        do {
            oldSem = sem;
            sem.wait();
        } while (sem != oldSem); // Make sure semaphore wasn't reset
        return super._processMessageQueue(c);
    }

    void step(int steps=1) {
        for (;steps>0; steps--)
            sem.notify();
    }

    void reset(uint steps=0) {
        auto oldsem = sem;
        sem = new Semaphore(steps);
        sem.notify;
    }

    void shutdown() {
        running = false;
        step(1000);
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
    s.step();
    LOG.info("Client open, sending assetRequest");
    auto client = createClient(s);
    auto ids = [new Identifier(message.HashType.SHA1, cast(ubyte[])x"c1531277498f21cb9ded5741f7a0d66c66505bca")];
    bool gotTimeout = false;
    client.open(ids, delegate(IAsset asset, Status status, OpenOrUploadRequest req, OpenResponse resp) {
        assert(!asset, "Asset is not null");
        if (status == Status.TIMEOUT) {
            LOG.info("SUCCESS: Timeout gotten");
            client.close();
        } else {
            assert(false, "Expected Timeout but got other status " ~ toString(status));
        }
        assert(req, "Invalid request");
        assert(!resp, "Got unexpected response");
    }, TimeSpan.fromMillis(500));
    LOG.info("Request sent, expecting Timeout");
    client.run();
}

/****************************************************************************************
 * Verifies that the bithorde server times out stale forwarded requests correctly.
 ***************************************************************************************/
void testServerTimeout(SteppingServer src, SteppingServer proxy) {
    src.step();
    proxy.step(100);
    Thread.sleep(0.1);
    auto client = createClient(proxy);
    LOG.info("Client open, sending assetRequest");
    auto ids = [new Identifier(message.HashType.SHA1, cast(ubyte[])x"c1531277498f21cb9ded5741f7a0d66c66505bca")];
    bool gotTimeout = false;
    auto sendTime = Clock.now;
    client.open(ids, delegate(IAsset asset, Status status, OpenOrUploadRequest req, OpenResponse resp) {
        assert(!asset, "Asset is not null");
        if (status == Status.NOTFOUND) {
            gotTimeout = true;
            client.close();
        } else {
            assert(false, "Expected NOTFOUND but got other status " ~ toString(status));
        }
        auto elapsed = Clock.now - sendTime;
        assert(elapsed.millis > 300, "Too little time has passed. Can't be result of Timeout.");
        assert(req, "Invalid request");
        assert(resp, "Did not get expected response");
    }, TimeSpan.fromMillis(500));
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
    client.beginUpload(testData.length*times, delegate(IAsset _asset, Status status, OpenOrUploadRequest req, OpenResponse resp) {
        auto asset = cast(RemoteAsset)_asset;
        assert(asset && (status == Status.SUCCESS), "Failed opening");
        for (int i = 0; i < times; i++)
            asset.sendDataSegment(i*testData.length,cast(ubyte[])testData);

        asset.requestMetaData(delegate (IAsset asset, Status status, MetaDataRequest req, MetaDataResponse resp) {
            assert(asset && (status == Status.SUCCESS), "Failed digesting");
            retVal = resp.ids;
            LOG.info("SUCCESS! Digest is {}", retVal[0].id);
            client.close();
        });
    });
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

    void gotResponse(IAsset asset, Status status, ReadRequest req, ReadResponse resp) {
        assert(status == Status.SUCCESS, "Read should have succeded, but got status " ~ toString(status));
        pos += chunkSize;
        if (pos < asset.size)
            asset.aSyncRead(pos, chunkSize, &gotResponse);
        else {
            LOG.info("SUCCESS: Got asset despite timeout");
            client.close();
        }
    }

    client.open(ids, delegate(IAsset _asset, Status status, OpenOrUploadRequest req, OpenResponse resp) {
        asset = cast(RemoteAsset)_asset;
        assert(asset && (status == Status.SUCCESS), "Failed opening");

        asset.aSyncRead(pos, chunkSize, &gotResponse, 500);
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

    auto proxy = new SteppingServer("RestartProxy", 23416, [src]);
    proxy.reset(1000);
    auto client = createClient(proxy);
    LOG.info("Client open, trying to open asset");

    uint pos;
    RemoteAsset asset;

    void gotResponse1(IAsset asset, Status status, ReadRequest req, ReadResponse resp) {
        assert(status == Status.SUCCESS, "First-Read should have succeded, but got status " ~ toString(status));
        client.close();
    }
    client.open(ids, delegate(IAsset _asset, Status status, OpenOrUploadRequest req, OpenResponse resp) {
        asset = cast(RemoteAsset)_asset;
        assert(asset && (status == Status.SUCCESS), "Failed opening, status is " ~ statusToString(status));

        asset.aSyncRead(0, chunkSize, &gotResponse1, 500);
    });
    client.run();
    LOG.info("Shutting down server");
    proxy.shutdown();
    LOG.info("Restarting server");
    proxy = new SteppingServer("RestartProxy", 23416, [src]);
    proxy.reset(1000);
    LOG.info("Reconnection client");
    client = createClient(proxy);

    void gotResponse2(IAsset asset, Status status, ReadRequest req, ReadResponse resp) {
        assert(status == Status.SUCCESS, "Read should have succeded, but got status " ~ toString(status));
        pos += chunkSize;
        if (pos < asset.size)
            asset.aSyncRead(pos, chunkSize, &gotResponse2);
        else {
            LOG.info("SUCCESS: Got asset even after restart timeout");
            client.close();
        }
    }
    LOG.info("Retrying fetch");
    client.open(ids, delegate(IAsset _asset, Status status, OpenOrUploadRequest req, OpenResponse resp) {
        asset = cast(RemoteAsset)_asset;
        assert(asset && (status == Status.SUCCESS), "Failed opening");

        asset.aSyncRead(pos, chunkSize, &gotResponse2, 500);
    });
    client.run();
}

/*----------------------- Actual tests begin here -------------------------------------*/

/// Log for all the tests
static Logger LOG;

/// Execute all the tests in order
void main() {
    Log.root.add(new AppendConsole(new LayoutDate));
    LOG = Log.lookup("libtest");

    Stdout("\nTesting ClientTimeout\n=====================\n").newline;
    auto src = new SteppingServer("Src", 23412);
    scope(exit) src.shutdown();
    testLibTimeout(src);

    Stdout("\nTesting ServerTimeout\n=====================\n").newline;
    auto proxy = new SteppingServer("Proxy", 23415, [src]);
    scope(exit) proxy.shutdown();
    testServerTimeout(src, proxy);

    Stdout("\nTesting AssetUpload\n===================\n").newline;
    auto ids = testAssetUpload(src);

    Stdout("\nTesting Asset Fetching With Retry on Timeouts\n=============================================\n").newline;
    testAssetFetchWithTimeout(src, ids);

    Stdout("\nTesting Restarting During Partial Asset\n=======================================\n").newline;
    testRestartWithPartialAsset(src, ids);
}