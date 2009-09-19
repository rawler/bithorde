module clients.bhget;

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

    void onRead(IAsset asset, ulong offset, ubyte[] data, BHStatusCode status) {
        Stdout(cast(char[])data);
        offset += data.length;
        auto length = asset.size - offset;
        if (length > 1024)
            length = 1024;
        if (length > 0)
            asset.aSyncRead(offset, length, &onRead);
        else
            doRun = false;
    }

    c.open(BitHordeMessage.HashType.SHA1, hexToBytes(args[1]),
        delegate void(IAsset asset, BHStatusCode status) {
            auto length = asset.size - offset;
            if (length > 1024)
                length = 1024;
            asset.aSyncRead(offset, length, &onRead);
    });
    while (doRun) {
        c.read();
    }
}