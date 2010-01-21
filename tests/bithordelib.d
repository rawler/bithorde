module tests.libbithorde;

private import tango.core.Thread;
private import tango.core.sync.Semaphore;
private import tango.io.Stdout;
private import tango.net.device.LocalSocket;
private import tango.net.device.Socket;

import daemon.server;
import daemon.config;

import lib.client;
import lib.message;

class SteppingServer : Server {
    Semaphore sem;
    Thread thread;

    this(char[] name, ushort port) {
        auto c = new Config;
        c.name = "TestServer-"~name;
        c.port = 1337;
        c.unixSocket = "/tmp/bithorde-test-"~name;
        c.cachedir = "cache-test-"~name;
        // c.friends is unset;
        sem = new Semaphore;

        super(c);

        thread = new Thread(&run);
        thread.isDaemon = true;
        thread.start();
    }

    void run() {
        while (true) {
            sem.wait();
            pump();
        }
    }

    void step() {
        sem.notify();
    }
}

void testTimeout(SteppingServer s) {
    s.step();
    Stdout("Opening Client...").newline;
    auto client = new Client(new LocalAddress(s.config.unixSocket), "libtest");
    Stdout("Client open, sending assetRequest").newline;
    auto ids = [new Identifier(message.HashType.SHA1, cast(ubyte[])x"c1531277498f21cb9ded5741f7a0d66c66505bca")];
    bool gotTimeout = false;
    client.open(ids, delegate(IAsset asset, Status status, OpenOrUploadRequest req, OpenResponse resp) {
        assert(!asset, "Asset is not null");
        if (status == Status.TIMEOUT)
            gotTimeout = true;
        else
            assert(false, "Expected Timeout but got other status");
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

void main() {
    auto server = new SteppingServer("A", 23412);
    testTimeout(server);
}