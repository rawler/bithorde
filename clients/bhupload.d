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
module clients.bhupload;

import tango.core.Exception;
import tango.io.device.File;
import tango.io.FilePath;
import tango.io.Stdout;
import tango.net.device.Berkeley;
import tango.net.device.LocalSocket;
import tango.net.device.Socket;
import tango.text.convert.Layout;
import tango.time.Clock;
import tango.util.container.SortedMap;
import tango.util.Convert;
import tango.text.convert.Format;
import tango.stdc.posix.unistd;
import tango.sys.Environment;

import lib.client;
import lib.hashes;
import lib.message;
import lib.arguments;
import clients.lib.progressbar;

const uint CHUNK_SIZE = 32768;

/****************************************************************************************
 * BHUpload-implementation of Argument-parsing.
 ***************************************************************************************/
class UploadArguments : private Arguments {
private:
    char[] sockPath;
    FilePath file;
    bool verbose;
    bool progressBar;
    bool link = false;
public:
    /************************************************************************************
     * Setup and configure underlying parser.
     ***********************************************************************************/
    this() {
        this["verbose"].aliased('v').smush;
        this["progressBar"].aliased('p').params(1).restrict(autoBool).smush.defaults("auto");
        this["unixsocket"].aliased('u').params(1).smush.defaults("/tmp/bithorde");
        this["link"].aliased('l').smush;
        this[null].title("file").required.params(1);
    }

    /************************************************************************************
     * Do the real parsing and convert to plain D-attributes.
     ***********************************************************************************/
    bool parse(char[][] arguments) {
        if (!super.parse(arguments))
            throw new IllegalArgumentException("Failed to parse arguments\n:" ~ errors(&stderr.layout.sprint));

        file = new FilePath(this[null].assigned[0]);
        if (!file.exists)
            throw new IllegalArgumentException("File does not exist");
        if (!file.isFile)
            throw new IllegalArgumentException("File is not a regular file");

        link = this["link"].set;

        progressBar = getAutoBool("progressBar", delegate bool() {
            return isatty(2) == 1 && !link;
        });
        verbose = this["verbose"].set;
        sockPath = this["unixsocket"].assigned[0];

        return true;
    }
}

/****************************************************************************************
 * Main BHUpload class, does the actual file-handling and sending to BitHorde
 ***************************************************************************************/
class BHUpload
{
private:
    RemoteAsset asset;    /// Writeable BitHorde asset
    SimpleClient client;  /// BitHorde client instance
    int exitStatus;
    UploadArguments args;
    File file;            /// File to read from
    ulong pos;            /// Send-position, for progressBar

    ProgressBar pBar;     /// ProgressBar, if desired
public:
    /************************************************************************************
     * Setup from Args, create BitHorde-asset, and begin sending the file
     ***********************************************************************************/
    this(UploadArguments args) {
        this.args = args;
        Address addr = new LocalAddress(args.sockPath);
        client = new SimpleClient(addr, "bhupload");

        if (args.link) {
            auto path = args.file.absolute(Environment.cwd);
            if (args.verbose)
                Stderr.format("Linking path {}...", path).newline;
            client.registerLink(args.file.absolute(Environment.cwd), &onStatusUpdate);
        } else {
            file = new File(args.file.toString);

            client.beginUpload(file.length, &onStatusUpdate);
            client.sigWriteClear.attach(&fillQueue);
        }
    }
    ~this(){
        if (asset)
            asset.close();
        client.close();
    }

    /**************************************************************************
     * Drive the main loop, pumping responses from bithorde to their handlers
     *************************************************************************/
    void run()
    {
        client.run();
    }
private:
    /************************************************************************************
     * Finalize pushing, and exit with status
     ***********************************************************************************/
    void exit(int exitStatus) {
        if (asset)
            asset.detachWatcher(&onStatusUpdate);
        client.close();
        this.exitStatus = exitStatus;
    }

    /************************************************************************************
     * Called-back from asset.beginUpload. If sucessful, start pushing the file
     ***********************************************************************************/
    void onStatusUpdate(IAsset _asset, Status status, AssetStatus resp) {
        switch (status) {
        case Status.SUCCESS:
            asset = cast(RemoteAsset)_asset;
            if (resp.idsIsSet) {
                return onComplete(asset, status, resp.ids);
            } else {
                // Re-register this handle to recieve status updates
                asset.attachWatcher(&onStatusUpdate);
                if (file)
                    sendFile(asset);
                return;
            }
        default:
            if (resp)
                Stderr.format("Got unexpected status from BitHorde.open: {}", statusToString(status)).newline;
            else
                Stderr.format("Client-side aborted with failure-code: {}", statusToString(status)).newline;
            return exit(-1);
        }
    }

    /************************************************************************************
     * Since BitHorde does not reply to file-pushing, the entire file can safely be
     * pushed in one go.
     ***********************************************************************************/
    void sendFile(RemoteAsset asset) {
        if (args.verbose)
            Stderr.format("File upload begun.").newline;
        if (args.progressBar)
            pBar = new ProgressBar(file.length, args.file.name ~ " : ", "kB", 1024);

        pos = file.position;
        fillQueue(client);
    }

    void fillQueue(Client c) {
        ubyte[CHUNK_SIZE] buf;
        file.seek(pos);
        while (pos < file.length) {
            ssize_t read = file.read(buf);
            if (read != file.Eof) {
                auto oldPos = pos;
                if (asset.sendDataSegment(oldPos, buf[0..read])) {
                    pos += read;
                    if (pBar)
                        pBar.update(pos);
                } else {
                    break;
                }
            }
        }
    }

    /************************************************************************************
     * When the entire file is pushed, bithorde will reply with calculated checksums.
     * Print these, and exit
     ***********************************************************************************/
    void onComplete(IAsset asset, Status status, Identifier[] ids) {
        if (args.progressBar) {
            if (exitStatus == 0) // Successful finish
                pBar.finish(pos);
            else
                Stderr.newline;
        }
        if (status == Status.SUCCESS) {
            Stdout(formatMagnet(ids, pos, args.file.file)).newline;
            foreach (id; ids) if (id.type == HashType.ED2K) {
                Stdout(formatED2K(ids, pos, args.file.file)).newline;
            }
            exit(0);
        } else {
            Stderr("Non-successful upload", statusToString(status)).newline;
            exit(status);
        }
    }
}

/****************************************************************************************
 * Parse args, and run BHGet
 ***************************************************************************************/
int main(char[][] args)
{
    auto arguments = new UploadArguments;
    try {
        arguments.parse(args[1..length]);
    } catch (IllegalArgumentException e) {
        if (e.msg)
            Stderr(e.msg).newline;
        Stderr.format("Usage: {} [--verbose|-v] [{{--link|-l}] [{{--progressBar|-p}}=yes/no] [--unixsocket|u=/tmp/bithorde] <uri>", args[0]).newline;
        return -1;
    }
    scope auto b = new BHUpload(arguments);
    b.run();
    return b.exitStatus;
}
