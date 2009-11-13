module clients.bhget;

import tango.core.Exception;
import tango.io.device.File;
import tango.io.model.IConduit;
import tango.io.Stdout;
import tango.net.InternetAddress;
import tango.net.device.Berkeley;
import tango.net.device.Socket;
import tango.text.convert.Layout;
import tango.time.Clock;
import tango.util.ArgParser;
import tango.util.container.SortedMap;
import tango.util.Convert;
import tango.stdc.posix.unistd;

import tango.net.LocalAddress;

import lib.hashes;
import lib.client;
import lib.message;

const uint CHUNK_SIZE = 4096;
const uint PARALLEL_REQUESTS = 5;
const auto updateThreshold = TimeSpan.fromMillis(50);
const auto bwWindow = TimeSpan.fromMillis(500);

class Arguments : private ArgParser {
    enum OutMode {
        AUTO,
        STDOUT,
        FILE,
    }
    enum ProgressBar {
        AUTO,
        ON,
        OFF,
    }
private:
    char[] sockPath;
    Identifier[] ids;
    char[] name;
    bool verbose;
    ProgressBar progress = ProgressBar.AUTO;
    OutMode outMode = OutMode.AUTO;
public:
    this(char[][] arguments) {
        super(delegate void(char[] value,uint ordinal) {
            if (ordinal > 0) {
                throw new IllegalArgumentException("Only 1 uri supported");
            } else {
                ids = parseUri(value, name);
                if (!ids)
                    throw new IllegalArgumentException("Failed to parse Uri. Supported styles are magnet-links, and ed2k-links");
            }
        });
        sockPath = "/tmp/bithorde";
        bindPosix(["verbose", "v"], delegate void(char[] value) {
            verbose = true;
        });
        bindPosix(["progress", "p"], delegate void(char[] value) {
            progress = ProgressBar.ON;
        });
        bindPosix(["no-progress", "P"], delegate void(char[] value) {
            progress = ProgressBar.OFF;
        });
        bindPosix(["stdout", "s"], delegate void(char[] value) {
            outMode = OutMode.STDOUT;
        });
        bindPosix(["no-stdout", "S"], delegate void(char[] value) {
            outMode = OutMode.FILE;
        });
        parse(arguments);
        if (!ids)
            throw new IllegalArgumentException("Missing objectid");

        switch (outMode) {
            case OutMode.FILE:
                if (!name)
                    throw new IllegalArgumentException("Output forced to file, but no filename found in URI");
                break;
            case OutMode.AUTO:
                outMode = name ? OutMode.FILE : OutMode.STDOUT;
                break;
            default:
        }

        if (progress == ProgressBar.AUTO) {
            if (isatty(2) && (!isatty(1) || outMode == OutMode.FILE))
                progress = ProgressBar.ON;
            else
                progress = ProgressBar.OFF;
        }
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
    Arguments args;
    Time startTime;
    Time lastTime;
    Time lastBwTime;
    ulong lastBwOffset;
    ulong currentBw;
    ushort lastProgressSize;
    Layout!(char) progressLayout;
public:
    this(Arguments args) in {
        assert(args.outMode != Arguments.OutMode.AUTO, "args.outMode must be decided");
        assert(args.progress != Arguments.ProgressBar.AUTO, "args.progress must be decided");
    } body {
        this.args = args;
        Address addr = new LocalAddress(args.sockPath);
        auto socket = new Socket(addr.addressFamily, SocketType.STREAM, ProtocolType.IP);
        socket.connect(addr);
        client = new Client(socket, "bhget");

        doRun = true;
        switch (args.outMode) {
            case Arguments.OutMode.STDOUT:
                output = new SortedOutput(Stdout);
                break;
            case Arguments.OutMode.FILE:
                output = new SortedOutput(new File(args.name, File.WriteCreate));
                break;
        }

        if (args.progress == Arguments.ProgressBar.ON)
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
        if (args.progress == Arguments.ProgressBar.ON) {
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
        if (args.progress == Arguments.ProgressBar.ON)
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
            if (args.progress == Arguments.ProgressBar.ON) {
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
    Arguments arguments;
    try {
        arguments = new Arguments(args[1..length]);
    } catch (IllegalArgumentException e) {
        if (e.msg)
            Stderr(e.msg).newline;
        Stderr.format("Usage: {} [--verbose|-v] [--progress|-P] [--host|-h=<hostname>] [--port|-p=<port>] <uri>", args[0]).newline;
        return -1;
    }
    scope auto b = new BHGet(arguments);
    b.run();
    return b.exitStatus;
}
