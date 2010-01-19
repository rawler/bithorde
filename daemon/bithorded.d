module daemon.bithorded;

private import tango.io.Stdout;
private import tango.stdc.posix.signal;
private import tango.util.log.AppendConsole;
private import tango.util.log.LayoutDate;
private import tango.util.log.Log;

private import daemon.config;
private import daemon.server;

/**
 * Main entry for server daemon
 */
public int main(char[][] args)
{
    if (args.length != 2) {
        Stderr.format("Usage: {} <config>", args[0]).newline;
        return -1;
    }

    // Hack, since Tango doesn't set MSG_NOSIGNAL on send/recieve, we have to explicitly ignore SIGPIPE
    signal(SIGPIPE, SIG_IGN);

    auto config = new Config(args[1]);

    auto consoleOut = new AppendConsole(new LayoutDate);
    Log.root.add(consoleOut);

    scope Server s = new Server(config);
    s.run();

    return 0;
}
