module daemon.bithorded;

private import tango.core.Thread;
private import tango.core.Runtime;
private import tango.io.Console;
private import tango.io.Stdout;
private import tango.stdc.posix.signal;
private import tango.util.log.AppendConsole;
private import tango.util.log.AppendFile;
private import tango.util.log.LayoutDate;
private import tango.util.log.Log;

private import daemon.config;
private import daemon.server;

extern (C) {
    int fork();
    void exit(int);
}

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

    // Parse config
    auto config = new Config(args[1]);

    // Setup logging
    if (config.doDebug)
        Log.root.add(new AppendConsole(new LayoutDate));
    else if (config.logfile)
        Log.root.add(new AppendFile(config.logfile.toString, new LayoutDate));

    // Try to setup server instance
    scope Server s = new Server(config);

    // Daemonize
    if (!config.doDebug) {
        Cin.input.close();
        Cout.output.close();
        Cerr.output.close();
        if (fork() != 0) exit(0);
    }

    s.run();

    return 0;
}
