/****************************************************************************************
 * Tiny limited http-server-implementation over the Pumping IO-framework.
 *
 * Copyright (C) 2010 Ulrik Mikaelsson <ulrik.mikaelsson@gmail.com>
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
 ****************************************************************************************/

module lib.httpserver;

import tango.net.device.Berkeley;
import tango.net.device.Socket;
import tango.text.Util;
import tango.util.Convert;
import tango.util.log.Log;
import tango.util.MinMax;

import lib.pumping;

const CRLF = "\r\n";

struct HTTPTriplet {
    const SEP = " ";
    char[256] buf;
    char[] code, url, httpver;
    void parse(char[] line) {
        assert(line.length <= buf.length);
        buf[0..line.length] = line;
        line = buf[0..line.length];
        code = head(line, SEP, line);
        url = head(line, SEP, httpver);
    }
    void write(size_t delegate(void[]) dg) {
        dg(httpver);
        dg(SEP);
        dg(code);
        dg(SEP);
        dg(url);
        dg(CRLF);
    }
}

struct HTTPHeader {
    const SEP = ": ";
    char[256] buf;
    char[] name, value;
    void parse(char[] line) {
        assert(line.length <= buf.length);
        buf[0..line.length] = line;
        line = buf[0..line.length];
        name = head(line, SEP, value);
    }
    void write(size_t delegate(void[]) dg) {
        dg(name);
        dg(SEP);
        dg(value);
        dg(CRLF);
    }
}

struct HTTPMessage {
    HTTPTriplet command;
    HTTPHeader[] headers;
    void[] payload;
    bool complete = false;

    void newHeader(char[] line) {
        headers.length = headers.length + 1;
        auto hdr = &headers[$-1];
        hdr.parse(line);
    }

    size_t push(char[] buffer) {
        size_t read, next = 0;
        while (!complete && ((next = locatePattern(buffer, CRLF, read)) < buffer.length)) {
            auto line = buffer[read..next];
            if (command.code.length == 0)
                command.parse(line);
            else if (line == "")
                complete = true;
            else
                newHeader(line);
            read = next + CRLF.length;
        }
        return read;
    }
    void write(size_t delegate(void[]) dg) {
        command.write(dg);
        foreach (hdr; headers)
            hdr.write(dg);
        dg(CRLF);
        dg(payload);
    }

    void respond(ushort code, char[] content, char[] mimeType="text/plain") {
        command.code = to!(char[])(code);
        addHeader("Content-Type", mimeType);
        payload = content;
    }

    void addHeader(char name[], char[] value) {
        headers.length = headers.length + 1;
        auto hdr = &headers[$-1];
        hdr.name = name;
        hdr.value = value;
    }
}

alias void delegate(HTTPMessage* request, out HTTPMessage response) HTTPHandler;

class HTTPConnection : BaseSocket {
    HTTPMessage currentRequest;
    HTTPHandler handler;
    ubyte[] buf;

    this(Pump p, Socket s, HTTPHandler handler) {
        super(p, s, 16*1024);
        this.handler = handler;
    }
    size_t onData(ubyte[] data) {
        auto consumed = currentRequest.push(cast(char[])data);
        if (currentRequest.complete) {
            HTTPMessage response;
            handler(&currentRequest, response);
            response.command.httpver = currentRequest.command.httpver;
            if (!response.command.code) {
                response.command = currentRequest.command;
                response.command.code = "500";
            }
            size_t buffer(void[] _buf) {
                buf ~= cast(ubyte[])_buf;
                return _buf.length;
            }
            response.write(&buffer);
            writeReply();
        }
        return consumed;
    }

    void writeReply() {
        while (buf.length) {
            auto written = this.write(buf[0..min!(uint)(1024,buf.length)], true);
            if (written)
                buf = buf[written..$];
            else
                return; // Wait for next onWriteClear
        }
        this.close();
    }

    void onWriteClear() {
        writeReply();
    }
}

class HTTPPumpingServer : BaseSocketServer!(ServerSocket) {
    HTTPHandler handler;

    this(Pump p, char[] address, ushort port, HTTPHandler handler) {
        auto addr = new IPv4Address(address, port);
        super(p, new ServerSocket(addr, 32, true));
        this.handler = handler;
    }
    HTTPConnection onConnection(Socket s) {
        return new HTTPConnection(pump, s, handler);
    }
}

struct MgmtEntry {
    char[] name;
    char[] value;
    bool islink;
    static MgmtEntry link(char[] name, char[] value) {
        return MgmtEntry(name, value, true);
    }
}

class HTTPMgmtProxy {
    alias MgmtEntry[] delegate(char[][]path) Handler;

    static class Error: Exception {
        ushort httpcode;
        this(ushort httpcode, char[] msg = "Error in MgmtDispatch") {
            this.httpcode = httpcode;
            super(msg);
        }
    }
private:
    char[] title;
    Handler root;
    Logger log;
public:
    this(char[] title, Handler root) {
        this.title = title;
        this.root = root;
        this.log = Log.lookup("httpmgmtproxy");
    }

    void opCall(HTTPMessage* request, out HTTPMessage response) {
        if (request.command.code != "GET")
            return response.respond(405, "Only GET-requests supported");

        auto path = delimit(strip(request.command.url, '/'), "/");
        if (path[0] == "")
            path = path[1..$];

        try {
            auto res = root(path);

            bool renderHTML = false;
            foreach (h; request.headers) {
                if (h.name == "Accept" && containsPattern(h.value, "text/html"))
                    renderHTML = true;
            }

            auto responseString = renderHTML ? formatHTML(res) : formatText(res);
            auto mimeType = renderHTML ? "text/html" : "text/plain";
            return response.respond(200, responseString, mimeType);
        } catch (Error e) {
            return response.respond(e.httpcode, e.msg);
        } catch (Exception e) {
            log.trace("Internal error: {}, {}:{}", e, e.file, e.line);
            return response.respond(500, "Internal error");
        }
    }

private:
    char[] formatText(MgmtEntry[] entries) {
        char[] res;
        foreach (entry; entries) {
            char[1024] buf;
            if (entry.islink)
                res ~= layout(buf, " -> %0 : %1\n", entry.name, entry.value);
            else
                res ~= layout(buf, " %0 : %1\n", entry.name, entry.value);
        }
        return res;
    }

    char[] formatHTML(MgmtEntry[] entries) {
        char[2048] buf;
        char[] res = layout(buf, "<html>
<head>
<title>%0</title>
<style type=\"text/css\">
table {
  border: 1px solid #A3A3A3;
  border-collapse: collapse;
  border-spacing: 0px;
}
th {
  background-color: #BBCCFF;
}
td {
  border: 1px solid #A3A3A3;
  border-collapse: collapse;
  border-spacing: 0px;
  padding-right: 10px;
  padding-left: 5px;
}
</style>
</head>
<body>
    <h1>%0</h1>
    <table><tr><th>Name</th><th>Description</th>
", title).dup;
        foreach (entry; entries) {
            if (entry.islink)
                res ~= layout(buf, "<tr><td><a href=\"%0\">%0</a></td><td>%1</td><tr>\n", entry.name, entry.value);
            else
                res ~= layout(buf, "<tr><td>%0</td><td>%1</td><tr>\n", entry.name, entry.value);
        }
        res ~= "</table></body></html>";
        return res;
    }
}

debug (HTTPPumpingTest) {
    import tango.io.Stdout;

    void main() {
        void echo(HTTPMessage* request, out HTTPMessage response) {
            response.command = request.command;
            response.command.code = "200";
            response.payload = request.command.url~"\n";
        }

        auto pump = new Pump;
        auto server = new HTTPPumpingServer(pump, "localhost", 1339, &echo);
        pump.run();
    }
}
