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
import daemon.friend;

import lib.client;
import lib.message;

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

void testLibTimeout(SteppingServer s) {
    Stdout("Testing ClientTimeout\n=====================\n").newline;
    s.step();
    Stdout("Opening Client...").newline;
    auto client = new Client(new LocalAddress(s.config.unixSocket), "libtest");
    Stdout("Client open, sending assetRequest").newline;
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
    });
    Stdout("Request sent, expecting Timeout").newline;
    client.run();
    if (gotTimeout)
        Stdout("SUCCESS: Timeout gotten").newline;
    else
        assert(false, "Did not get timeout");
}

void testServerTimeout(SteppingServer src, SteppingServer proxy) {
    Stdout("\nTesting ServerTimeout\n=====================").newline;
    src.step();
    for (int i=0; i < 100; i++)
        proxy.step();
    Thread.sleep(0.1);
    Stdout("Opening Client...").newline;
    auto client = new Client(new LocalAddress(proxy.config.unixSocket), "libtest");
    Stdout("Client open, sending assetRequest").newline;
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
    Stdout("Request sent, expecting Timeout").newline;
    client.run();
    if (gotTimeout)
        Stdout("SUCCESS: NOTFOUND after Timeout").newline;
    else
        assert(false, "Did not get timeout");

}

void main() {
    Log.root.add(new AppendConsole(new LayoutDate));

    auto src = new SteppingServer("A", 23412);
    testLibTimeout(src);
    src = new SteppingServer("Src", 23414);
    auto proxy = new SteppingServer("Proxy", 23415, [src]);
    testServerTimeout(src, proxy);
}