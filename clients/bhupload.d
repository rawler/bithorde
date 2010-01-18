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

const uint CHUNK_SIZE = 4096;

class UploadArguments : private Arguments {
private:
    char[] sockPath;
    FilePath file;
    bool verbose;
    bool progressBar;
public:
    this() {
        this["verbose"].aliased('v').smush;
        this["progressBar"].aliased('p').params(1).restrict(autoBool).smush.defaults("auto");
        this["unixsocket"].aliased('u').params(1).smush.defaults("/tmp/bithorde");
        this[null].title("file").required.params(1);
    }

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

class BHUpload
{
private:
    bool doRun;
    RemoteAsset asset;
    Client client;
    int exitStatus;
    UploadArguments args;
    File file;
    ulong pos;

    ProgressBar pBar;
public:
    this(UploadArguments args) {
        this.args = args;
        Address addr = new LocalAddress(args.sockPath);
        auto socket = new Socket(addr.addressFamily, SocketType.STREAM, ProtocolType.IP);
        socket.connect(addr);
        client = new Client(socket, "bhupload");

        doRun = true;
        file = new File(args.file.toString);

        client.beginUpload(file.length, &onOpen);
    }
    ~this(){
        asset.close();
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

                if (pBar)
                    pBar.update(pos);
            } else {
                Stderr("Failed to read chunk from pos").newline;
                exit(-1);
            }
        }
        if (args.progressBar) {
            if (exitStatus == 0) // Successful finish
                pBar.finish(pos);
            else
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

    void onOpen(IAsset asset, Status status, OpenOrUploadRequest req, OpenResponse resp) {
        switch (status) {
        case Status.SUCCESS:
            if (args.verbose)
                Stderr.format("File upload begun.").newline;
            if (args.progressBar)
                pBar = new ProgressBar(file.length, args.file.name ~ " : ", "kB", 1024);
            this.asset = cast(RemoteAsset)asset;
            break;
        default:
            Stderr.format("Got unknown status from BitHorde.open: {}", status).newline;
            return exit(-1);
        }
    }

    void onComplete(IAsset asset, Status status, MetaDataRequest req, MetaDataResponse resp) {
        doRun = false;
        if (status == Status.SUCCESS) {
            Stdout(formatMagnet(resp.ids, pos, args.file.file)).newline;
            Stdout(formatED2K(resp.ids, pos, args.file.file)).newline;
        }
        else
            Stderr("Non-successful upload").newline;
    }
}

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
