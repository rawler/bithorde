module clients.bhget;

import tango.io.Console;
import tango.net.InternetAddress;
import tango.net.SocketConduit;

import lib.connection;

void main(char[][])
{
    auto socket = new SocketConduit();
    socket.connect(new InternetAddress("localhost", 4567));

    auto c = new Connection(socket);

    auto r = new BHOpenRequest;
    r.priority = 128;
    r.hash = BitHordeMessage.HashType.SHA1;
    r.id = cast(ubyte[])x"abcf2cde12525134";
    c.sendRequest(BitHordeMessage.Type.OpenRequest, r);
}