module clients.bhget;

import tango.io.Console;
import tango.io.Stdout;
import tango.net.InternetAddress;
import tango.net.SocketConduit;

import lib.client;
import lib.message;

void main(char[][] args)
{
    auto socket = new SocketConduit();
    socket.connect(new InternetAddress("localhost", 4567));

    auto c = new Client(socket);
    bool doRun = true;
    ulong offset;

    void exit() {
        doRun = false;
    }

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

    c.open(BitHordeMessage.HashType.SHA1, hexToBytes(args[1]),
        delegate void(IAsset asset, BHStatus status) {
            switch (status) {
            case BHStatus.SUCCESS:
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