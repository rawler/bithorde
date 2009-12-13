module clients.bhget;

import tango.core.Exception;
import tango.io.device.File;
import tango.io.model.IConduit;
import tango.io.Stdout;
import tango.net.InternetAddress;
import tango.net.device.Berkeley;
import tango.net.device.LocalSocket;
import tango.net.device.Socket;
import tango.text.convert.Layout;
import tango.time.Clock;
import tango.util.container.SortedMap;
import tango.util.Convert;
import tango.stdc.posix.unistd;

import lib.hashes;
import lib.client;
import lib.message;
import lib.arguments;

const uint CHUNK_SIZE = 4096;
const uint PARALLEL_REQUESTS = 5;
const auto updateThreshold = TimeSpan.fromMillis(50);
const auto bwWindow = TimeSpan.fromMillis(500);

class GetArguments : protected Arguments {
private:
    char[] sockPath;
    Identifier[] ids;
    char[] name;
    bool verbose;
    bool progressBar;
    bool stdout;
public:
    this() {
        sockPath = "/tmp/bithorde";
        this["verbose"].aliased('v').smush;
        this["progressBar"].aliased('p').params(1).restrict(autoBool).smush.defaults("auto");
        this["stdout"].aliased('s').params(1).restrict(autoBool).smush.defaults("auto");
        this[null].title("uri").required.params(1);
    }

    bool parse(char[][] arguments) {
        if (!super.parse(arguments))
            throw new IllegalArgumentException("Failed to parse arguments:\n" ~ errors(&stderr.layout.sprint));

        ids = parseUri(this[null].assigned[0], name);
        if (!ids)
            throw new IllegalArgumentException("Failed to parse Uri. Supported styles are magnet-links, and ed2k-links");

        stdout = getAutoBool("stdout", delegate bool() {
            return !name;
        });

        progressBar = getAutoBool("progressBar", delegate bool() {
            return isatty(2) && (!isatty(1) || !stdout);
        });

        verbose = this["verbose"].set;

        return true;
    }
}

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
    void queue(ulong offset, ubyte[] data) {
        assert(offset >= currentOffset); // Maybe should handle a buffer beginning earlier as well?
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
            _queue.add(offset, data);
        }
    }
}

class BHGet
{
private:
    bool doRun;
    SortedOutput output;
    IAsset asset;
    Client client;
    ulong orderOffset;
    int exitStatus;
    GetArguments args;
    Time startTime;
    Time lastTime;
    Time lastBwTime;
    ulong lastBwOffset;
    ulong currentBw;
    ushort lastProgressSize;
    Layout!(char) progressLayout;
public:
    this(GetArguments args) {
        this.args = args;
        Address addr = new LocalAddress(args.sockPath);
        auto socket = new Socket(addr.addressFamily, SocketType.STREAM, ProtocolType.IP);
        socket.connect(addr);
        client = new Client(socket, "bhget");

        doRun = true;
        if (args.stdout)
            output = new SortedOutput(Stdout);
        else
            output = new SortedOutput(new File(args.name, File.WriteCreate));

        if (args.progressBar)
            progressLayout = new Layout!(char);

        client.open(args.ids, &onOpen);
    }
    ~this(){
        delete asset;
        delete client;
    }

    void run()
    {
        while (doRun && ((asset is null) || (output.currentOffset < asset.size))) {
            if (!client.readAndProcessMessage()) {
                Stderr("Server disconnected").newline;
                exit(-1);
            }
        }
        if (args.stdout) {
            if (exitStatus == 0) { // Successful finish
                lastBwOffset = 0;
                lastBwTime = startTime;
                lastTime = startTime;
                updateProgress(true); // Display final avg BW.
            }
            Stderr.newline;
        }
    }
private:
    void exit(int exitStatus) {
        doRun = false;
        this.exitStatus = exitStatus;
    }

    void updateProgress(bool forced = false) {
        auto now = Clock.now;
        if (((now - lastTime) > updateThreshold) || forced) {
            lastTime = now;
            auto bwTime = now - lastBwTime;
            if ((bwTime > bwWindow) || forced) {
                currentBw = ((orderOffset - lastBwOffset) * 1000000) / bwTime.micros;
                lastBwTime = now;
                lastBwOffset = orderOffset;
            }
            auto bar = "------------------------------------------------------------";
            auto percent = (orderOffset * 100) / asset.size;
            auto barlen  = (orderOffset * bar.length) / asset.size;
            for (int i; i < barlen; i++)
                bar[i] = '*';

            auto progressSize = progressLayout.convert(Stderr, "\x0D[{}] {}% {}kB/s", bar, percent, currentBw);
            for (int i = progressSize; i < lastProgressSize; i++)
                Stderr(' ');
            lastProgressSize = progressSize;
            Stderr.flush;
        }
    }

    void onRead(IAsset asset, ulong offset, ubyte[] data, Status status) {
        assert(asset == this.asset);
        output.queue(offset, data);
        auto newoffset = offset + data.length;
        orderData();
        if (args.progressBar)
            updateProgress();
    }

    void orderData() {
        auto length = asset.size - orderOffset;
        if (length > CHUNK_SIZE)
            length = CHUNK_SIZE;
        if (length > 0) {
            this.asset.aSyncRead(orderOffset, length, &onRead);
            orderOffset += length;
        }
    }

    void onOpen(IAsset asset, Status status) {
        switch (status) {
        case Status.SUCCESS:
            if (args.verbose)
                Stderr.format("Asset found, size is {}kB.", asset.size / 1024).newline;
            if (args.progressBar) {
                startTime = Clock.now;
                lastTime = Clock.now;
                lastBwTime = Clock.now;
            }
            this.asset = asset;
            for (uint i; i < PARALLEL_REQUESTS; i++)
                orderData();
            break;
        case Status.NOTFOUND:
            Stderr("Asset not found in BitHorde").newline;
            return exit(-1);
        default:
            Stderr.format("Got unknown status from BitHorde.open: {}", status).newline;
            return exit(-1);
        }
    }
}

int main(char[][] args)
{
    auto arguments = new GetArguments;
    try {
        arguments.parse(args[1..length]);
    } catch (IllegalArgumentException e) {
        if (e.msg)
            Stderr(e.msg).newline;
        Stderr.format("Usage: {} [--verbose|-v] [{{--stdout|-s}}=yes/no] [{{--progressBar|-p}}=yes/no] <uri>", args[0]).newline;
        return -1;
    }

    scope auto b = new BHGet(arguments);
    b.run();
    return b.exitStatus;
}
