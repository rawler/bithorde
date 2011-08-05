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
module clients.bhget;

import tango.core.Exception;
import tango.io.device.File;
import tango.io.model.IConduit;
import tango.io.Stdout;
import tango.net.InternetAddress;
import tango.net.device.Berkeley;
import tango.net.device.LocalSocket;
import tango.net.device.Socket;
import tango.text.convert.Format;
import tango.text.Util;
import tango.time.Clock;
import tango.util.container.SortedMap;
import tango.util.Convert;
import tango.stdc.posix.unistd;

import lib.hashes;
import lib.client;
import lib.message;
import lib.arguments;

import clients.lib.progressbar;

const uint CHUNK_SIZE = 16384;    /// How large chunks to fetch
const uint PARALLEL_REQUESTS = 5; /// How many requests to keep running in parallell.

/****************************************************************************************
 * BHGet-implementation of Argument-parsing.
 ***************************************************************************************/
class GetArguments : protected Arguments {
private:
    char[] socketUri;
    Identifier[] ids;
    char[] name;
    bool verbose;
    bool progressBar;
    bool stdout;
public:
    /************************************************************************************
     * Setup and configure underlying parser.
     ***********************************************************************************/
    this() {
        this["verbose"].aliased('v').smush;
        this["progressBar"].aliased('p').params(1).restrict(autoBool).smush.defaults("auto");
        this["stdout"].aliased('s').params(1).restrict(autoBool).smush.defaults("auto");
        this["sockuri"].aliased('u').params(1).smush.defaults("/tmp/bithorde");
        this[null].title("uri").required.params(1);
    }

    /************************************************************************************
     * Do the real parsing and convert to plain D-attributes.
     ***********************************************************************************/
    bool parse(char[][] arguments) {
        if (!super.parse(arguments))
            throw new IllegalArgumentException("Failed to parse arguments:\n" ~ errors(&stderr.layout.sprint));

        auto id_arg = this[null].assigned[0];
        ids = parseUri(id_arg, name);
        if (!ids)
            ids = parseLink(id_arg, name);
        if (!ids)
            throw new IllegalArgumentException("Failed to parse Uri. Supported asset-specs are magnet-links, or a symlink with a filename being a magnet-link.");

        if (name) {
            char[] _;
            name = tail(name, "/", _);
        }

        stdout = getAutoBool("stdout", delegate bool() {
            return !name;
        });
        progressBar = getAutoBool("progressBar", delegate bool() {
            return isatty(2) && (!isatty(1) || !stdout);
        });
        verbose = this["verbose"].set;
        socketUri = this["sockuri"].assigned[0];

        return true;
    }

    private Identifier[] parseLink(char[] arg, ref char[] fname) {
        char[4096] buf;
        ssize_t len = readlink((arg~'\0').ptr, buf.ptr, buf.length);
        if (len > 0) {
            char[] dirname;
            auto uri = tail(buf[0..len], "/", dirname);
            return parseUri(uri, fname);
        } else {
            fname = null;
            return null;
        }
    }
}

/****************************************************************************************
 * Class supporting recieving arbitary chunks in mixed-offset-order, and writing them to
 * output in-order.
 ***************************************************************************************/
class SortedOutput {
private:
    OutputStream _output;
    SortedMap!(ulong, ubyte[]) _queue;
public:
    ulong currentOffset;
    this(OutputStream output) {
        _output = output;
        _queue = new SortedMap!(ulong, ubyte[]);
    }
    ulong queue(ulong offset, ubyte[] data) {
        assert(offset >= currentOffset);
        if (offset == currentOffset) {
            _output.write(data);
            currentOffset += data.length;
            while ((_queue.size>0) && _queue.firstKey == currentOffset) {
                ubyte[] buf;
                _queue.take(buf);
                _output.write(buf);
                currentOffset += buf.length;
            }
        } else {
            _queue.add(offset, data.dup);
        }
        return currentOffset;
    }
    void flush() {
        _output.flush();
    }
}

/************************************************************************************
 * Separate structure for keeping track of request-response times.
 ***********************************************************************************/
struct RequestStats {
    class NotFoundException : Exception { this() { super("Entry not found"); } }
    struct Entry {
        ulong offset;
        size_t size;
        Time time;
    }
    Entry[PARALLEL_REQUESTS] inFlight;

    ulong worst_ms;
    ulong sum_ms;
    ulong count;

    void markBegin(ulong offset, size_t size, Time now) {
        foreach (i, ent; inFlight) {
            if (ent.time == Time.init) {
                inFlight[i] = Entry(offset, size, now);
                return;
            }
        }
        assert(false); // Should not reach here.
    }

    void markDone(ulong offset, size_t size, Time now) {
        foreach (i, ent; inFlight) {
            if (ent.offset == offset && ent.size == size) {
                auto delta = (now-ent.time).millis;
                if (delta > worst_ms)
                    worst_ms = delta;
                sum_ms += delta;
                count += 1;

                inFlight[i] = Entry.init;
                return;
            }
        }
        throw new NotFoundException;
    }
}

/****************************************************************************************
 * Main BHGet class, does the actual fetching, and sends to SortedOutput
 ***************************************************************************************/
class BHGet
{
private:
    SortedOutput output; /// Output in sorting fashion
    IAsset asset;        /// Remote Asset in bithorde
    SimpleClient client; /// BitHorde-client
    ulong orderOffset;   /// Which offset should be requested next?
    int exitStatus;      /// When done, what's the exitStatus?
    GetArguments args;   /// Args for the fetch
    ProgressBar pBar;    /// Progressbar, if desired

    RequestStats rStats; /// Room for request-time bookkeeping.
public:
    /************************************************************************************
     * Setup output and send async request for opening specified asset
     ***********************************************************************************/
    this(GetArguments args) {
        this.args = args;
        Address addr;
        if (args.socketUri[0] == '/') {
            addr = new LocalAddress(args.socketUri);
        } else {
            auto addrSpec = split(args.socketUri, ":");
            assert(addrSpec.length == 2);
            addr = new InternetAddress(addrSpec[0], to!(int)(addrSpec[1]));
        }
        client = new SimpleClient(addr, "bhget");

        if (args.stdout)
            output = new SortedOutput(Stdout);
        else
            output = new SortedOutput(new File(args.name, File.WriteCreate));

        client.open(args.ids, &onStatusUpdate);
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
        if (pBar) {
            if (exitStatus == 0) // Successful finish
                pBar.finish(orderOffset);
            else
                Stderr.newline;
            if (args.verbose) {
                auto count = rStats.count;
                auto avg = count?rStats.sum_ms/count:0;
                auto worst = rStats.worst_ms;
                Stderr.format("Requests: {} Avg: {}ms Worst: {}ms", count, avg, worst).newline;
            }
        }
    }
private:
    /************************************************************************************
     * Finalize fetching, and exit with status
     ***********************************************************************************/
    void exit(int exitStatus) {
        client.close();
        this.exitStatus = exitStatus;
    }
    /************************************************************************************
     * Exit with error-message
     ***********************************************************************************/
    void exit_error(int status, char[] msg, ...) {
        Stderr("ERROR: ");
        Format.convert(delegate uint(char[] s) {
                auto count = Stderr.stream.write (s);
                if (count is Stderr.Eof)
                    Stderr.conduit.error ("FormatOutput :: unexpected Eof");
                return count;
            }, _arguments, _argptr, msg);
        Stderr.newline;
        exit(status);
    }

    /************************************************************************************
     * Callback for when asset-open response is recieved.
     ***********************************************************************************/
    void onStatusUpdate(IAsset asset, Status status, AssetStatus resp) {
        switch (status) {
        case Status.SUCCESS:
            if (args.verbose)
                Stderr.format("Asset found, size is {}kB.", asset.size / 1024).newline;

            if (args.progressBar) {
                char[] junk;
                pBar = new ProgressBar(asset.size, (args.name ? tail(args.name, "/", junk) : "<unnamed>") ~ " : ", "kB", 1024);
            }

            this.asset = asset;

            // Send out the amount of requests that we should hold-in-flight
            // Note: Bithorde will automatically limit segment-orders to the size of the asset,
            //       so works even when assetsize < PARALLEL_REQUESTS*CHUNK_SIZE
            for (uint i; i < PARALLEL_REQUESTS; i++)
                orderData();
            break;
        case Status.NOTFOUND:
            return exit_error(-1, "Asset not found in BitHorde");
        default:
            return exit_error(-1, "Got unknown status from BitHorde.open: {}", statusToString(status));
        }
    }

    /************************************************************************************
     * Orders the next needed chunk of data.
     ***********************************************************************************/
    void orderData() {
        auto length = asset.size - orderOffset;
        if (length > CHUNK_SIZE)
            length = CHUNK_SIZE;
        if (length > 0) {
            if (args.verbose)
                rStats.markBegin(orderOffset, length, Clock.now);
            this.asset.aSyncRead(orderOffset, length, &onRead);
            orderOffset += length;
        }
    }

    /************************************************************************************
     * When new data arrives, order more, or exit if done
     ***********************************************************************************/
    void onRead(Status status, ReadRequest req, ReadResponse resp) {
        if (status != Status.SUCCESS)
            return exit_error(-1, "Read-failure, status {}", statusToString(status));
        if (req.size > resp.content.length)
            return exit_error(-1, "Segment-mismatch, got less than asked for.");
        if (req.offset != resp.offset)
            return exit_error(-1, "Segment-mismatch, wrong offset");
        if (args.verbose)
            rStats.markDone(resp.offset, resp.content.length, Clock.now);

        if (output.queue(resp.offset, resp.content) >= asset.size)
            exit(0);
        else
            orderData();
        if (pBar)
            pBar.update(orderOffset);
    }
}

/****************************************************************************************
 * Parse args, and run BHGet
 ***************************************************************************************/
int main(char[][] args)
{
    auto arguments = new GetArguments;
    try {
        arguments.parse(args[1..length]);
    } catch (IllegalArgumentException e) {
        if (e.msg)
            Stderr(e.msg).newline;
        Stderr.format("Usage: {} [--verbose|-v] [{{--stdout|-s}}=yes/no] [{{--progressBar|-p}}=yes/no] [--unixsocket|u=/tmp/bithorde] <uri>", args[0]).newline;
        return -1;
    }

    scope auto b = new BHGet(arguments);
    b.run();
    return b.exitStatus;
}
