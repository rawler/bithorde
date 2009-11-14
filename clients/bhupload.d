module clients.bhupload;

import tango.core.Exception;
import tango.io.device.File;
import tango.io.FilePath;
import tango.io.Stdout;
import tango.net.device.Berkeley;
import tango.net.device.Socket;
import tango.text.convert.Layout;
import tango.time.Clock;
import tango.util.ArgParser;
import tango.util.container.SortedMap;
import tango.util.Convert;
import tango.net.LocalAddress;
import tango.text.convert.Format;

import lib.client;
import lib.hashes;
import lib.message;

const uint CHUNK_SIZE = 4096;
const auto updateThreshold = TimeSpan.fromMillis(50);
const auto bwWindow = TimeSpan.fromMillis(500);

class Arguments : private ArgParser {
private:
    char[] sockPath;
    FilePath file;
    bool verbose;
    bool progress = true;
public:
    this(char[][] arguments) {
        super(delegate void(char[] value,uint ordinal) {
            if (ordinal > 0) {
                throw new IllegalArgumentException("Only 1 file supported");
            } else {
                file = new FilePath(value);
            }
        });
        sockPath = "/tmp/bithorde";
        bindPosix(["unixsocket", "u"], delegate void(char[] value) {
            sockPath = value;
        });
        bindPosix(["verbose", "v"], delegate void(char[] value) {
            verbose = true;
        });
        bindPosix(["progress", "p"], delegate void(char[] value) {
            progress = true;
        });
        bindPosix(["progress", "P"], delegate void(char[] value) {
            progress = false;
        });
        parse(arguments);
        if (!file)
            throw new IllegalArgumentException("Missing filename");
        if (!file.exists)
            throw new IllegalArgumentException("File does not exist");
        if (!file.isFile)
            throw new IllegalArgumentException("File is not a regular file");
    }
}

class BHUpload
{
private:
    bool doRun;
    RemoteAsset asset;
    Client client;
    int exitStatus;
    Arguments args;
    File file;
    ulong pos;

    Time startTime;
    Time lastTime;
    Time lastBwTime;
    ulong lastBwPos;
    ulong currentBw;
    ushort lastProgressSize;
    Layout!(char) progressLayout;
public:
    this(Arguments args) {
        this.args = args;
        Address addr = new LocalAddress(args.sockPath);
        auto socket = new Socket(addr.addressFamily, SocketType.STREAM, ProtocolType.IP);
        socket.connect(addr);
        client = new Client(socket, "bhupload");

        doRun = true;
        file = new File(args.file.toString);
        if (args.progress)
            progressLayout = new Layout!(char);

        client.beginUpload(file.length, &onOpen);
    }
    ~this(){
        delete asset;
        delete client;
    }

    void run()
    {
        while (doRun && (asset is null)) {
            if (!client.readAndProcessMessage()) {
                Stderr("Server disconnected").newline;
                exit(-1);
            }
        }
        pos = file.position;
        while (doRun && pos < file.length) {
            ubyte[CHUNK_SIZE] buf;
            auto read = file.read(buf);
            if (read > 0) {
                asset.sendDataSegment(pos, buf[0..read]);
                pos += read;

                if (args.progress)
                    updateProgress();
            } else {
                Stderr("Failed to read chunk from pos").newline;
                exit(-1);
            }
        }
        if (args.progress) {
            if (exitStatus == 0) { // Successful finish
                lastBwPos = 0;
                lastBwTime = startTime;
                lastTime = startTime;
                updateProgress(); // Display final avg BW.
            }
            Stderr.newline;
        }
        asset.requestMetaData(&onComplete);
        while (doRun) { // Wait for completion
            if (!client.readAndProcessMessage()) {
                Stderr("Server disconnected").newline;
                exit(-1);
            }
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
                currentBw = ((pos - lastBwPos) * 1000) / bwTime.millis;
                lastBwTime = now;
                lastBwPos = pos;
            }
            auto bar = "------------------------------------------------------------";
            auto percent = (pos * 100) / file.length;
            auto barlen  = (pos * bar.length) / file.length;
            for (int i; i < barlen; i++)
                bar[i] = '*';

            auto progressSize = progressLayout.convert(Stderr, "\x0D[{}] {}% {}kB/s", bar, percent, currentBw);
            for (int i = progressSize; i < lastProgressSize; i++)
                Stderr(' ');
            lastProgressSize = progressSize;
            Stderr.flush;
        }
    }

    void onOpen(IAsset asset, Status status) {
        switch (status) {
        case Status.SUCCESS:
            if (args.verbose)
                Stderr.format("File upload begun.").newline;
            if (args.progress) {
                startTime = Clock.now;
                lastTime = Clock.now;
                lastBwTime = Clock.now;
            }
            this.asset = cast(RemoteAsset)asset;
            break;
        default:
            Stderr.format("Got unknown status from BitHorde.open: {}", status).newline;
            return exit(-1);
        }
    }

    void onComplete(IAsset asset, MetaDataResponse resp) {
        doRun = false;
        if (resp.status == Status.SUCCESS) {
            Stdout(formatMagnet(resp.ids, pos, args.file.file)).newline;
            Stdout(formatED2K(resp.ids, pos, args.file.file)).newline;
        }
        else
            Stderr("Non-successful upload").newline;
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
        Stderr.format("Usage: {} [--verbose|-v] [--progress|-P] [--unixsocket|-u=<socket path>] <file>", args[0]).newline;
        return -1;
    }
    scope auto b = new BHUpload(arguments);
    b.run();
    return b.exitStatus;
}
