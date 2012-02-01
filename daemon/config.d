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
module daemon.config;

private import tango.io.device.File;
private import tango.io.FilePath;
private import tango.io.stream.Map;
private import tango.net.InternetAddress;
private import Text = tango.text.Util;
private import tango.text.Unicode;
private import tango.time.Time;
private import tango.util.Convert;
private import base64 = tango.util.encode.Base64;

private import daemon.routing.friend;
private import lib.message;

/****************************************************************************************
 * Exception thrown when config failed parsing
 ***************************************************************************************/
class ConfigException : Exception
{
    this (char[] msg) { super(msg); }
}

/****************************************************************************************
 * Convert string values into boolean values
 ***************************************************************************************/
bool parseBool(char[] value) {
    switch (toLower(value)) {
        case "yes", "true", "1":
            return true;
        case "no", "false", "0":
            return false;
        default:
            throw new ConfigException("Expected boolean but got '"~value~"'");
    }
}

class Client : ConfiguredConnection {
    this(char[] name) {
        super(name);
    }
}

/****************************************************************************************
 * Parses the BitHorded Config File
 ***************************************************************************************/
class Config
{
    char[] name;
    ushort port = 1337;
    char[] unixSocket = "/tmp/bithorde";
    ushort httpPort = 0;
    char[] setuid, setgid;
    FilePath cachedir;
    ulong cacheMaxSize;                        /// Maximum cacheSize, in MB
    FilePath[] linkroots;
    FilePath logfile;
    Friend[char[]] friends;
    Client[char[]] clients;
    bool doDebug = false;
    bool usefsync = false;
    bool allowanon = true;
    TimeSpan heartbeat = TimeSpan.fromSeconds(20);

    /************************************************************************************
     * Create Config object from file
     ***********************************************************************************/
    this (char[] configFileName) {
        scope configFile = new File(configFileName, File.ReadExisting);
        scope config = new MapInput!(char)(configFile);

        foreach (name, value; config) {
            char[] option;
            auto section= Text.head(name, ".", option);
            if (!option)
                throw new ConfigException("Names in config needs to have at least 2 parts");
            switch (section) {
            case "server":
                parseServerOption(option, value);
                break;
            case "friend":
                parseFriendOption(option, value);
                break;
            case "client":
                parseClientOption(option, value);
                break;
            default:
                throw new ConfigException("Unknown config section");
            }
        }

        validate();
    }

    this() {
    }

    /************************************************************************************
     * Check that all required options were given
     ***********************************************************************************/
    void validate() {
        if (!name)
            throw new ConfigException("Missing server.name");
    }

    ConfiguredConnection findConnectionParams(char[] name) {
        if (name in friends)
            return friends[name];
        if (name in clients)
            return clients[name];
        return null;
    }
private:
    /**************************************************************************
     * Parse server.* - options
     *************************************************************************/
    void parseServerOption(char[] option, char[] value) {
        switch (option) {
        case "allowanon":
            this.allowanon = parseBool(value);
            break;
        case "cachedir":
            this.cachedir = new FilePath(value);
            break;
        case "cachesize":
            this.cacheMaxSize = to!(ulong)(value);
            break;
        case "debug":
            this.doDebug = parseBool(value);
            break;
        case "heartbeat":
            this.heartbeat = TimeSpan.fromInterval(to!(float)(value));
            break;
        case "httpport":
            this.httpPort = to!(ushort)(value);
            break;
        case "logfile":
            this.logfile = new FilePath(value);
            break;
        case "name":
            this.name = value.dup;
            break;
        case "port":
            this.port = to!(ushort)(value);
            break;
        case "setuid":
            this.setuid = value.dup;
            break;
        case "setgid":
            this.setgid = value.dup;
            break;
        case "unixsocket":
            if (value.length)
                this.unixSocket = value.dup;
            else
                this.unixSocket = null;
            break;
        case "usefsync":
            this.usefsync = parseBool(value);
            break;
        case "linkroots":
            foreach (root; Text.split(value.dup, ";")) {
                auto path = new FilePath(root);
                if (path.exists && path.isFolder)
                    linkroots ~= path;
                else
                    throw new ConfigException("Linkroot '"~root~"' is not an existing directory.");
            }
            break;
        default:
            throw new ConfigException("Unknown server option "~option);
        }
    }

    private CipherType mapCipher(char[] text) {
        switch (toLower(text)) {
            case "none":
            case "clear":
            case "cleartext":
                return CipherType.CLEARTEXT;
            case "xor":
                return CipherType.XOR;
            case "rc4":
            case "arc4":
            case "arcfour":
                return CipherType.RC4;
            case "aes":
            case "aes_ctr":
                return CipherType.AES_CTR;
            default:
                throw new ConfigException("Unrecognized cipher " ~ text);
        }
    }

    /************************************************************************************
     * Parse friend.* - options
     ***********************************************************************************/
    void parseFriendOption(char[] option, char[] value) {
        auto friendName = Text.head(option, ".", option);
        if (!option)
            throw new ConfigException("Missing friend option for " ~ friendName);
        if (!(friendName in friends))
            friends[friendName] = new Friend(friendName);
        auto friend = friends[friendName];

        switch (option) {
        case "addr":
            friend.addr = Text.head(value, ":", value);
            if (!value)
                throw new ConfigException("Wrong format on " ~ friendName ~ ".addr. Should be <host>:<port>");
            friend.port = to!(ushort)(value);
            break;
        case "key":
            friend.sharedKey = base64.decode(value);
            break;
        case "sendcipher":
            friend.sendCipher = mapCipher(value);
            break;
        default:
            throw new ConfigException("Unknown friend option: " ~ friendName ~ "." ~ option);
        }
    }

    void parseClientOption(char[] option, char[] value) {
        auto clientName = Text.head(option, ".", option);
        if (!option)
            throw new ConfigException("Missing client option for " ~ clientName);
        if (!(clientName in clients))
            clients[clientName] = new Client(clientName);
        auto client = clients[clientName];

        switch (option) {
        case "key":
            client.sharedKey = base64.decode(value);
            break;
        case "sendcipher":
            client.sendCipher = mapCipher(value);
            break;
        default:
            throw new ConfigException("Unknown client option: " ~ clientName ~ "." ~ option);
        }
    }
}
