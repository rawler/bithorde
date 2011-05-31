/****************************************************************************************
 * Tiny http-server-implementation over the Pumping IO-framework.
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

import lib.pumping;

    import tango.io.Stdout;

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
}

alias void delegate(HTTPMessage* request, out HTTPMessage response) HTTPHandler;

class HTTPConnection : BaseSocket {
    HTTPMessage currentRequest;
    HTTPHandler handler;

    this(Pump p, Socket s, HTTPHandler handler) {
        super(p, s, 16*1024);
        this.handler = handler;
    }
    size_t onData(ubyte[] data) {
        auto consumed = currentRequest.push(cast(char[])data);
        if (currentRequest.complete) {
            HTTPMessage response;
            handler(&currentRequest, response);

            if (!response.command.code) {
                response.command = currentRequest.command;
                response.command.code = "500";
            }
            ubyte[] buf;
            size_t buffer(void[] _buf) {
                buf ~= cast(ubyte[])_buf;
                return _buf.length;
            }
            response.write(&buffer);
            this.write(buf);
            this.close();
        }
        return consumed;
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

debug (HTTPPumpingTest) {
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