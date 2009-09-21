module clients.bhget;

import tango.core.Exception;
import tango.io.Console;
import tango.io.Stdout;
import tango.net.InternetAddress;
import tango.net.SocketConduit;
import tango.util.ArgParser;
import tango.util.Convert;

import lib.client;
import lib.message;

class Arguments : private ArgParser {
private:
    char[] host;
    ushort port;
    ubyte[] objectid;
public:
    this(char[][] arguments) {
        super(delegate void(char[] value,uint ordinal) {
            if (ordinal > 0) {
                throw new IllegalArgumentException("Only 1 objectid supported");
            } else {
                objectid = hexToBytes(value);
            }
        });
        host = "localhost";
        port = 1337;
        bindPosix(["host", "h"], delegate void(char[] value) {
            host = value;
        });
        bindPosix(["port", "p"], delegate void(char[] value) {
            port = to!(ushort)(value);
        });
        parse(arguments);
        if (!objectid)
            throw new IllegalArgumentException("Missing objectid");
    }
}

void bhget(Arguments args)
{
    auto socket = new SocketConduit();
    socket.connect(new InternetAddress(args.host, args.port));

    auto c = new Client(socket);
    bool doRun = true;
    ulong offset;

    void exit() {
        doRun = false;
    }

    scope IAsset openAsset;

    void onRead(IAsset asset, ulong offset, ubyte[] data, BHStatus status) {
        Cout(cast(char[])data);
        offset += data.length;
        auto length = asset.size - offset;
        if (length > 1024)
            length = 1024;
        if (length > 0)
            asset.aSyncRead(offset, length, &onRead);
        else
            exit();
    }

    c.open(BitHordeMessage.HashType.SHA1, args.objectid,
        delegate void(IAsset asset, BHStatus status) {
            switch (status) {
            case BHStatus.SUCCESS:
                openAsset = asset;
                auto length = asset.size - offset;
                if (length > 1024)
                    length = 1024;
                asset.aSyncRead(offset, length, &onRead);
                break;
            case BHStatus.NOTFOUND:
                Stderr("Asset not found in BitHorde").newline;
                return exit();
            default:
                Stderr.format("Got unknown status from BitHorde.open: {}", status).newline;
                return exit();
            }
    });
    while (doRun) {
        c.read();
    }
}

void main(char[][] args)
{
    Arguments arguments;
    try {
        arguments = new Arguments(args[1..length]);
    } catch (IllegalArgumentException e) {
        if (e.msg)
            Stderr(e.msg).newline;
        Stderr.format("Usage: {} [--host|-h=<hostname>] [--port|-p=<port>] <objectid>", args[0]);
        return -1;
    }
    bhget(arguments);
    return 0;
}