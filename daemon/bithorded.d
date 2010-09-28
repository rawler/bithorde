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

module daemon.bithorded;

private import tango.core.Thread;
private import tango.core.Runtime;
private import tango.io.Console;
private import tango.io.Stdout;
private import tango.stdc.posix.grp;
private import tango.stdc.posix.pwd;
private import tango.stdc.posix.signal;
private import tango.stdc.posix.unistd;
private import tango.stdc.stdlib;
private import tango.util.log.AppendConsole;
private import tango.util.log.AppendFile;
private import tango.util.log.LayoutDate;
private import tango.util.log.Log;

private import daemon.config;
private import daemon.server;

Server s;

extern (C) void exit_handler(int sig) {
    if (s) {
        Log.root.info("Shutting down on signal {}", sig);
        s.shutdown();
        s = null;
    } else {
        Log.root.fatal("Forcing quit");
        exit(-1);
    }
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

    // Exit_handler
    signal(SIGTERM, &exit_handler);

    // Parse config
    auto config = new Config(args[1]);

    // Setup logging
    if (config.doDebug)
        Log.root.add(new AppendConsole(new LayoutDate));
    else if (config.logfile)
        Log.root.add(new AppendFile(config.logfile.toString, new LayoutDate));

    // Try to setup server instance
    s = new Server(config);
    // Daemonize
    if (!config.doDebug) {
        Cin.input.close();
        Cout.output.close();
        Cerr.output.close();
        if (fork() != 0) exit(0);
    }

    // If root, drop privileges.
    if (geteuid() == 0) {
        auto log = Log.lookup("main");
        Log.lookup("main").info("Detected running as root. Dropping privileges to nobody");

        if (auto nogroup = getgrnam("nogroup")) {
            if (setegid(nogroup.gr_gid))
                log.error("Failed dropping group-privileges. Running with root privileges!");
        } else {
            log.error("Did not find user 'group'. Running with root privileges!");
        }

        if (auto nobody = getpwnam("nobody")) {
            if (seteuid(nobody.pw_uid))
                log.error("Failed dropping user-privileges. Running with root privileges!");
        } else {
            log.error("Did not find user 'nobody'. Running with root privileges!");
        }
    }

    s.run();

    return 0;
}
