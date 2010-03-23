/****************************************************************************************
 * Copyright: Ulrik Mikaelsson, All rights reserved
 ***************************************************************************************/
module daemon.routing.friend;

private import tango.net.InternetAddress;

private import daemon.client;

/****************************************************************************************
 * A Friend, as opposed to a client, is a node that requests can be forwarded to. This
 * class keeps track of configured friends, both connected and non-connected.
 ***************************************************************************************/
class Friend
{
package:
    /// Name is set on creation, and is immutable thereafter
    char[] _name;
    public char[] name() { return _name; }

    /// Mutable _addr may be changed during the lifetime of the object
    InternetAddress _addr;
    public InternetAddress addr() { return _addr; }
    public InternetAddress addr(InternetAddress v) { return _addr = v; }

    /// Set to a client instance, if friend is currently connected
    Client c;
    public bool isConnected() { return c !is null; }
    public void connected(Client c) { this.c = c; }
    public void disconnected() { this.c = null; }
public:
    this(char[] name)
    {
        _name = name;
    }
    this(char[] name, InternetAddress addr)
    {
        this(name);
        _addr = addr;
    }
}