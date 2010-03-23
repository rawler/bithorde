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
 **************************************************************************************/
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
public:
    /************************************************************************************
     * Setup and configure underlying parser.
     ***********************************************************************************/
    this() {
        this["verbose"].aliased('v').smush;
        this["progressBar"].aliased('p').params(1).restrict(autoBool).smush.defaults("auto");
        this["unixsocket"].aliased('u').params(1).smush.defaults("/tmp/bithorde");
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

        progressBar = getAutoBool("progressBar", delegate bool() {
            return isatty(2) == 1;
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
    Client client;        /// BitHorde client instance
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
        client = new Client(addr, "bhupload");

        file = new File(args.file.toString);

        client.beginUpload(file.length, &onOpen);
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
        client.close();
        this.exitStatus = exitStatus;
    }

    /************************************************************************************
     * Called-back from asset.beginUpload. If sucessful, start pushing the file
     ***********************************************************************************/
    void onOpen(IAsset asset, Status status, OpenOrUploadRequest req, OpenResponse resp) {
        switch (status) {
        case Status.SUCCESS:
            if (args.verbose)
                Stderr.format("File upload begun.").newline;
            if (args.progressBar)
                pBar = new ProgressBar(file.length, args.file.name ~ " : ", "kB", 1024);
            this.asset = cast(RemoteAsset)asset;
            sendFile();
            break;
        default:
            Stderr.format("Got unknown status from BitHorde.open: {}", status).newline;
            return exit(-1);
        }
    }

    /************************************************************************************
     * Since BitHorde does not reply to file-pushing, the entire file can safely be
     * pushed in one go.
     ***********************************************************************************/
    void sendFile() {
        pos = file.position;
        while (pos < file.length) {
            ubyte[CHUNK_SIZE] buf;
            auto read = file.read(buf);
            if (read > 0) {
                asset.sendDataSegment(pos, buf[0..read]);
                pos += read;

                if (pBar)
                    pBar.update(pos);
            } else {
                Stderr("Failed to read chunk from pos").newline;
                exit(-1);
            }
        }
        asset.requestMetaData(&onComplete);
        if (args.progressBar) {
            if (exitStatus == 0) // Successful finish
                pBar.finish(pos);
            else
                Stderr.newline;
        }
    }

    /************************************************************************************
     * When the entire file is pushed, bithorde will reply with calculated checksums.
     * Print these, and exit
     ***********************************************************************************/
    void onComplete(IAsset asset, Status status, MetaDataRequest req, MetaDataResponse resp) {
        if (status == Status.SUCCESS) {
            Stdout(formatMagnet(resp.ids, pos, args.file.file)).newline;
            Stdout(formatED2K(resp.ids, pos, args.file.file)).newline;
            exit(0);
        } else {
            Stderr("Non-successful upload").newline;
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
        Stderr.format("Usage: {} [--verbose|-v] [{{--progressBar|-p}}=yes/no] [--unixsocket|u=/tmp/bithorde] <uri>", args[0]).newline;
        return -1;
    }
    scope auto b = new BHUpload(arguments);
    b.run();
    return b.exitStatus;
}
