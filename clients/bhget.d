module clients.bhget;

import tango.core.Exception;
import tango.io.Stdout;
import tango.net.InternetAddress;
import tango.net.SocketConduit;
import tango.util.ArgParser;
import tango.util.container.SortedMap;
import tango.util.Convert;

import lib.client;
import lib.message;

const uint CHUNK_SIZE = 4096;
const uint PARALLEL_REQUESTS = 5;

class Arguments : private ArgParser {
private:
    char[] host;
    ushort port;
    ubyte[] objectid;
public:
    this(char[][] arguments) {
        super(delegate void(char[] value,uint ordinal) {
            if (ordinal > 0) {
                throw new IllegalArgumentException("Only 1 objectid supported");
            } else {
                objectid = hexToBytes(value);
            }
        });
        host = "localhost";
        port = 1337;
        bindPosix(["host", "h"], delegate void(char[] value) {
            host = value;
        });
        bindPosix(["port", "p"], delegate void(char[] value) {
            port = to!(ushort)(value);
        });
        parse(arguments);
        if (!objectid)
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
public:
    this(Arguments args) {
        auto socket = new SocketConduit();
        socket.connect(new InternetAddress(args.host, args.port));
        
        client = new Client(socket);
        doRun = true;
        output = new SortedOutput(Stdout);

        client.open(BitHordeMessage.HashType.SHA1, args.objectid, &onOpen);
    }
    ~this(){
        delete asset;
        delete client;
    }

    void run()
    {
        while (doRun && ((asset is null) || (output.currentOffset < asset.size))) {
            client.read();
        }
    }
private:
    void exit() {
        doRun = false;
    }

    void onRead(IAsset asset, ulong offset, ubyte[] data, BHStatus status) {
        assert(asset == this.asset);
        output.queue(offset, data);
        auto newoffset = offset + data.length;
        orderData();
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

    void onOpen(IAsset asset, BHStatus status) {
        switch (status) {
        case BHStatus.SUCCESS:
            this.asset = asset;
            for (uint i; i < PARALLEL_REQUESTS; i++)
                orderData();
            break;
        case BHStatus.NOTFOUND:
            Stderr("Asset not found in BitHorde").newline;
            return exit();
        default:
            Stderr.format("Got unknown status from BitHorde.open: {}", status).newline;
            return exit();
        }
    }
}

void main(char[][] args)
{
    Arguments arguments;
    try {
        arguments = new Arguments(args[1..length]);
    } catch (IllegalArgumentException e) {
        if (e.msg)
            Stderr(e.msg).newline;
        Stderr.format("Usage: {} [--host|-h=<hostname>] [--port|-p=<port>] <objectid>", args[0]);
        return -1;
    }
    scope auto b = new BHGet(arguments);
    b.run();
    return 0;
}