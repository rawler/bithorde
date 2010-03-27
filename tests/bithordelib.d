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
        foreach (srv; friends)
            c.friends[srv.name] = new Friend(srv.name, new InternetAddress("localhost", srv.config.port));

        sem = new Semaphore;
        super(c);

        thread = new Thread(&run);
        thread.isDaemon = true;
        thread.start();
    }

    bool processSelectEvent(SelectionKey event) {
        sem.wait();
        return super.processSelectEvent(event);
    }

    void step() {
        sem.notify();
    }
}

/****************************************************************************************
 * Verifies that the bithorde lib times out stale requests correctly.
 ***************************************************************************************/
void testLibTimeout(SteppingServer s) {
    s.step();
    LOG.info("Opening Client...");
    auto client = new Client(new LocalAddress(s.config.unixSocket), "libtest");
    LOG.info("Client open, sending assetRequest");
    auto ids = [new Identifier(message.HashType.SHA1, cast(ubyte[])x"c1531277498f21cb9ded5741f7a0d66c66505bca")];
    bool gotTimeout = false;
    client.open(ids, delegate(IAsset asset, Status status, OpenOrUploadRequest req, OpenResponse resp) {
        assert(!asset, "Asset is not null");
        if (status == Status.TIMEOUT) {
            gotTimeout = true;
            client.close();
        } else {
            assert(false, "Expected Timeout but got other status " ~ toString(status));
        }
        assert(req, "Invalid request");
        assert(!resp, "Got unexpected response");
    }, TimeSpan.fromMillis(500));
    LOG.info("Request sent, expecting Timeout");
    client.run();
    if (gotTimeout)
        LOG.info("SUCCESS: Timeout gotten");
    else
        assert(false, "Did not get timeout");
}

/****************************************************************************************
 * Verifies that the bithorde server times out stale forwarded requests correctly.
 ***************************************************************************************/
void testServerTimeout(SteppingServer src, SteppingServer proxy) {
    src.step();
    for (int i=0; i < 100; i++)
        proxy.step();
    Thread.sleep(0.1);
    LOG.info("Opening Client...");
    auto client = new Client(new LocalAddress(proxy.config.unixSocket), "libtest");
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

/// Log for all the tests
static Logger LOG;

/// Execute all the tests in order
void main() {
    Log.root.add(new AppendConsole(new LayoutDate));
    LOG = Log.lookup("libtest");

    Stdout("\nTesting ClientTimeout\n=====================\n").newline;
    auto src = new SteppingServer("A", 23412);
    testLibTimeout(src);

    Stdout("\nTesting ServerTimeout\n=====================\n").newline;
    src = new SteppingServer("Src", 23414);
    auto proxy = new SteppingServer("Proxy", 23415, [src]);
    testServerTimeout(src, proxy);
}