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
    ulong offset;
    ulong assetSize;
    ulong assetHandle;
    bool doRun = true;

    void onRead(BitHordeMessage response) {
        auto respData = new BHReadResponse;
        respData.decode(response.content);
        Stdout(cast(char[])respData.content);
        offset += respData.content.length;
        auto length = assetSize - offset;
        if (length > 1024)
            length = 1024;
        if (length > 0)
            c.readData(assetHandle, offset, length, &onRead);
        else
            doRun = false;
    }

    c.open(BitHordeMessage.HashType.SHA1, hexToBytes(args[1]),
        delegate void(BitHordeMessage response) {
        auto respData = new BHOpenResponse;
        respData.decode(response.content);
        assetSize = respData.size;
        assetHandle = respData.handle;
        auto length = assetSize - offset;
        if (length > 1024)
            length = 1024;
        c.readData(assetHandle, offset, length, &onRead);
    });
    while (doRun) {
        c.read();
    }
}