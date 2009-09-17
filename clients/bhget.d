module clients.bhget;

import tango.io.Stdout;
import tango.net.InternetAddress;
import tango.net.SocketConduit;

import lib.client;
import lib.message;

void main(char[][])
{
    auto socket = new SocketConduit();
    socket.connect(new InternetAddress("localhost", 4567));

    auto c = new Client(socket);
    c.open(BitHordeMessage.HashType.SHA1, cast(ubyte[])x"abcf2cde12525134",
        delegate void(BitHordeMessage response) {
        Stdout.format("Got response: {}", response).newline;
    });
    while (c.read()) {}
}