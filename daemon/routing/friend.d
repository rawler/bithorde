/****************************************************************************************
 *   Copyright: Copyright (C) 2009-2010 Ulrik Mikaelsson. All rights reserved
 *
 *   License:
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
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