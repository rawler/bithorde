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
private import tango.stdc.posix.sys.stat;
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

    auto log = Log.lookup("main");

    if (config.setgid) {
        if (auto group = getgrnam((config.setgid~'\0').ptr)) {
            if (setgid(group.gr_gid))
                log.error("Failed dropping group-privileges. Running with unmodified privileges!");
        } else {
            log.error("Did not find user '{}'. Running with unmodified privileges!", config.setgid);
        }
    }

    if (config.setuid) {
        if (auto user = getpwnam((config.setuid~'\0').ptr)) {
            if (setuid(user.pw_uid))
                log.error("Failed dropping user-privileges. Running with unmodified privileges!");
        } else {
            log.error("Did not find user '{}'. Running with unmodified privileges!", config.setuid);
        }
    }

    // We always want only the file-owner to be able to read files created.
    umask(07077);

    log.info("Setup done, starting server");

    s.run();

    return 0;
}
