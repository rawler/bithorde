module daemon.config;

private import tango.io.device.File;
private import tango.io.FilePath;
private import tango.io.stream.Map;
private import tango.net.InternetAddress;
private import Text = tango.text.Util;
private import tango.util.Convert;

private import daemon.friend;

class ConfigException : Exception
{
    this (char[] msg) { super(msg); }
}

class Config
{
    char[] name;
    ushort port = 1337;
    char[] unixSocket = "/tmp/bithorde";
    FilePath cachedir;
    Friend[char[]] friends;

    this (char[] configFileName) {
        scope auto configFile = new File(configFileName, File.ReadExisting);
        scope auto config = new MapInput!(char)(configFile);

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
            default:
                throw new ConfigException("Unknown config section");
            }
        }

        validate();
    }

    this() {
    }

    void validate() {
        if (!name)
            throw new ConfigException("Missing server.name");
        foreach (name, friend; friends) {
            if (!friend.addr)
                throw new ConfigException("Missing address for " ~ name);
        }
    }
private:
    void parseServerOption(char[] option, char[] value) {
        switch (option) {
        case "port":
            this.port = to!(ushort)(value);
            break;
        case "name":
            this.name = value.dup;
            break;
        case "unixsocket":
            if (value.length)
                this.unixSocket = value.dup;
            else
                this.unixSocket = null;
            break;
        case "cachedir":
            this.cachedir = new FilePath(value);
            break;
        default:
            throw new ConfigException("Unknown server option");
        }
    }

    void parseFriendOption(char[] option, char[] value) {
        auto friendName = Text.head(option, ".", option);
        if (!option)
            throw new ConfigException("Missing friend option for " ~ friendName);
        if (!(friendName in friends))
            friends[friendName] = new Friend(friendName);
        auto friend = friends[friendName];

        switch (option) {
        case "addr":
            auto host = Text.head(value, ":", value);
            if (!value)
                throw new ConfigException("Wrong format on " ~ friendName ~ ".addr. Should be <host>:<port>");
            auto port = to!(ushort)(value);
            friend.addr = new InternetAddress(host, port);
            break;
        default:
            throw new ConfigException("Unknown friend option: " ~ friendName ~ "." ~ option);
        }
    }
}