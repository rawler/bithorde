module daemon.friend;

private import tango.net.InternetAddress;

private import daemon.client;

class Friend
{
package:
    char[] name;
    InternetAddress addr;
    Client c;
public:
    this(char[] name, InternetAddress addr)
    {
        this.name = name;
        this.addr = addr;
    }
}