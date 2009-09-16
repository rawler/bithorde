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

    auto m = new BitHordeMessage();
    m.type = BitHordeMessage.Type.KeepAlive;
    m.id = 133;

    c.send(m);
}