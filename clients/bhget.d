module clients.bhget;

import tango.core.Exception;
import tango.io.Stdout;
import tango.net.InternetAddress;
import tango.net.Socket;
import tango.net.SocketConduit;
import tango.text.convert.Layout;
import tango.time.Clock;
import tango.util.ArgParser;
import tango.util.container.SortedMap;
import tango.util.Convert;

import tango.net.LocalAddress;

import lib.hashes;
import lib.client;
import lib.message;

const uint CHUNK_SIZE = 4096;
const uint PARALLEL_REQUESTS = 5;
const auto updateThreshold = TimeSpan.fromMillis(50);
const auto bwWindow = TimeSpan.fromMillis(500);

class Arguments : private ArgParser {
private:
    char[] host;
    ushort port;
    Identifier[] ids;
    bool verbose;
    bool progress;
public:
    this(char[][] arguments) {
        super(delegate void(char[] value,uint ordinal) {
            if (ordinal > 0) {
                throw new IllegalArgumentException("Only 1 uri supported");
            } else {
                ids = parseUri(value);
                if (!ids)
                    throw new IllegalArgumentException("Failed to parse Uri. Supported styles are magnet-links, and ed2k-links");
            }
        });
        host = "/tmp/bithorde";
        port = 1337;
        bindPosix(["host", "h"], delegate void(char[] value) {
            host = value;
        });
        bindPosix(["port", "p"], delegate void(char[] value) {
            port = to!(ushort)(value);
        });
        bindPosix(["verbose", "v"], delegate void(char[] value) {
            verbose = true;
        });
        bindPosix(["progress", "P"], delegate void(char[] value) {
            progress = true;
        });
        parse(arguments);
        if (!ids)
            throw new IllegalArgumentException("Missing objectid");
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
    this(Arguments args) {
        this.args = args;
        Address addr;
        if (args.host[0] == '/') {
            addr = new LocalAddress(args.host);
        } else {
            addr = new InternetAddress(args.host, args.port);
        }
        auto socket = new SocketConduit(addr.addressFamily, SocketType.STREAM, ProtocolType.IP);
        socket.connect(addr);
        client = new Client(socket, "bhget");

        doRun = true;
        output = new SortedOutput(Stdout);
        if (args.progress)
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
            if (!client.read()) {
                Stderr("Server disconnected").newline;
                exit(-1);
            }
        }
        if (args.progress) {
            if (exitStatus == 0) { // Successful finish
                lastBwOffset = 0;
                lastBwTime = startTime;
                lastTime = startTime;
                updateProgress(); // Display final avg BW.
            }
            Stderr.newline;
        }
    }
private:
    void exit(int exitStatus) {
        doRun = false;
        this.exitStatus = exitStatus;
    }

    void updateProgress() {
        auto now = Clock.now;
        if ((now - lastTime) > updateThreshold ) {
            lastTime = now;
            auto bwTime = now - lastBwTime;
            if (bwTime > bwWindow) {
                currentBw = ((orderOffset - lastBwOffset) * 1000) / bwTime.millis;
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
        if (args.progress)
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
            if (args.progress) {
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
        Stderr.format("Usage: {} [--verbose|-v] [--progress|-P] [--host|-h=<hostname>] [--port|-p=<port>] <objectid>", args[0]).newline;
        return -1;
    }
    scope auto b = new BHGet(arguments);
    b.run();
    return b.exitStatus;
}