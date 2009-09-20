module daemon.server;

private import tango.io.selector.SelectSelector;
private import tango.io.Stdout;
private import tango.net.ServerSocket;
private import tango.net.Socket;
private import tango.net.SocketConduit;
private import Text = tango.text.Util;
private import tango.util.Convert;

private import daemon.cache;
private import daemon.client;
private import lib.asset;
private import lib.message;

class ForwardedAsset : IAsset {
private:
    IAsset[] backingAssets;
    BHOpenCallback openCallback;
package:
    uint waitingResponses;
public:
    this (BHOpenCallback cb)
    {
        this.openCallback = cb;
        this.waitingResponses = 0;
    }
    void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
        backingAssets[0].aSyncRead(offset, length, cb);
    }
    ulong size() {
        return backingAssets[0].size;
    }
    void addBackingAsset(IAsset asset, BHStatus status) {
        switch (status) {
        case BHStatus.SUCCESS:
            backingAssets ~= asset;
            break;
        case BHStatus.NOTFOUND:
            break;
        }
        waitingResponses -= 1;
        if (waitingResponses <= 0)
            doCallback();
    }
package:
    void doCallback() {
        openCallback(this, (backingAssets.length > 0) ? BHStatus.SUCCESS : BHStatus.NOTFOUND);
    }
}

class Server : ServerSocket
{
package:
    ISelector selector;
    CacheManager cacheMgr;
    InternetAddress[] friends;
    Client[] connectedFriends;
public:
    this(ushort port, InternetAddress[] friends)
    {
        super(new InternetAddress(IPv4Address.ADDR_ANY, port), 32, true);
        this.selector = new SelectSelector;
        selector.register(this, Event.Read);
        this.cacheMgr = new CacheManager(".");
        this.friends = friends;
        foreach (f; friends) {
            attemptConnect(f);
        }
    }

    void run()
    {
        while (selector.select() > 0) {
            SelectionKey[] removeThese;
            foreach (SelectionKey event; selector.selectedSet()) {
                if (!processSelectEvent(event))
                    removeThese ~= event;
            }
            foreach (event; removeThese) {
                auto c = cast(Client)event.attachment;
                selector.unregister(event.conduit);
                c.hangup();
            }
        }
    }

    bool attemptConnect(InternetAddress friend) {
        auto socket = new SocketConduit();
        socket.connect(friend);
        auto c = onClientConnect(socket);
        connectedFriends ~= c;
        return true;
    }

    void forwardOpenRequest(BitHordeMessage.HashType hType, ubyte[] id, ubyte priority, BHOpenCallback callback, Client origin) {
        bool forwarded = false;
        auto asset = new ForwardedAsset(callback);
        foreach (client; connectedFriends) {
            if (client != origin) {
                asset.waitingResponses += 1;
                client.open(hType, id, &asset.addBackingAsset);
                forwarded = true;
            }
        }
        if (!forwarded)
            asset.doCallback();
    }
private:
    Client onClientConnect(SocketConduit s)
    {
        auto c = new Client(this, s);
        selector.register(s, Event.Read, c);
        Stdout.format("Client connected: {}", s.socket.remoteAddress).newline;
        return c;
    }

    bool processSelectEvent(SelectionKey event)
    {
        if (event.conduit is this) {
            assert(event.isReadable);
            onClientConnect(accept());
        } else {
            auto c = cast(Client)event.attachment;
            if (event.isError || event.isHangup || event.isInvalidHandle) {
                return false;
            } else {
                assert (event.isReadable);
                return c.read();
            }
        }
        return true;
    }
}

/**
 * Main entry for server daemon
 */
public int main(char[][] args)
{
    if (args.length<2) {
        Stdout.format("Usage: {} <server-port> [friend1:port] [friend2:port] ...", args[0]).newline;
        return -1;
    }

    auto port = to!(uint)(args[1]);

    InternetAddress[] friends;
    foreach (arg; args[2..length]) {
        char[][] part = Text.delimit(arg, ":");
        friends ~= new InternetAddress(part[0], to!(ushort)(part[1]));
    }

    Server s = new Server(port, friends);
    s.run();

    return 0;
}