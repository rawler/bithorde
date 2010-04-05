/****************************************************************************************
 * Definition of all the BitHorde low-level protocol-buffers messages.
 *
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

module lib.message;

private import tango.core.Exception;
private import tango.core.Memory;
private import tango.core.sync.Mutex;
private import tango.util.container.more.Stack;

private import lib.protobuf;

enum Type
{
    HandShake = 1,
    OpenRequest = 2,
    OpenResponse = 3,
    Close = 4,
    ReadRequest = 5,
    ReadResponse = 6,
    UploadRequest = 7,
    DataSegment = 8,
    MetaDataRequest = 9,
    MetaDataResponse = 10,
}

public abstract class Message : ProtoBufMessage {
private:
    static Mutex listMutex;
    static Stack!(void*, 100) _freeList;
    static this () {
        listMutex = new Mutex();
    }
    new(size_t sz) {
        assert(sz <= 100, "Error, allocating too much");
        synchronized (listMutex) {
            if (_freeList.size)
                return _freeList.pop();
        } // Else
        return GC.malloc(128);
    }
    delete(void * p) {
        synchronized (listMutex) {
            if (_freeList.unused)
                return _freeList.push(p);
        } // Else
        GC.free(p);
    }
protected:
public:
    abstract Type typeId();
}

enum HashType
{
    SHA1 = 1,
    SHA256 = 2,
    TREE_TIGER = 3,
    ED2K = 4,
}

enum Status {
    NONE = 0,
    SUCCESS = 1,
    NOTFOUND = 2,
    INVALID_HANDLE = 3,
    WOULD_LOOP = 4,
    DISCONNECTED = 5,
    TIMEOUT = 6,
}
char[] statusToString(Status s) {
    static char[][] _map = [
        "NONE",
        "SUCCESS",
        "NOTFOUND",
        "INVALID_HANDLE",
        "WOULD_LOOP",
        "DISCONNECTED",
        "TIMEOUT",
    ];
    if (s >= _map.length)
        return "<unknown>";
    else
        return _map[s];
}

abstract class RPCMessage : Message {
    ushort rpcId;    // Local-link request id
}

abstract class RPCRequest : RPCMessage {
    ushort timeout;
    abstract void abort(Status s);
}

abstract class RPCResponse : RPCMessage {
    RPCRequest request;
    ~this() {
        if (request)
            delete request;
    }
}

private import lib.asset;

/****** Start defining the messages *******/
class Identifier : ProtoBufMessage {
    this(HashType t, ubyte[] id) {
        this.type = t;
        this.id = id;
    }
    this() {}
    HashType type;
    ubyte[] id;
    mixin MessageMixin!(PBField!("type", 1)(),
                        PBField!("id",   2)());
}

class HandShake : Message {
    char[] name;
    ubyte protoversion;
    mixin MessageMixin!(PBField!("name", 1)(),
                        PBField!("protoversion", 2)());
    Type typeId() { return Type.HandShake; }
}

package class OpenOrUploadRequest : RPCRequest {
}

class OpenRequest : OpenOrUploadRequest {
    Identifier ids[];  // Asset-Id:s to look for
    ulong uuid;        // UUID to avoid loops

    mixin MessageMixin!(PBField!("rpcId",    1)(),
                        PBField!("ids",      2)(),
                        PBField!("uuid",     3)(),
                        PBField!("timeout",  4)());

    Type typeId() { return Type.OpenRequest; }
}

class UploadRequest : OpenOrUploadRequest {
    ulong size;        // Size of opened asset
    mixin MessageMixin!(PBField!("rpcId",     1)(),
                        PBField!("size",      2)(),
                        PBField!("timeout",   3)());

    Type typeId() { return Type.UploadRequest; }
}

class OpenResponse : RPCResponse {
    Status status;     // Status of request
    ushort handle;     // Assigned handle
    ulong size;        // Size of opened asset
    mixin MessageMixin!(PBField!("rpcId",     1)(),
                        PBField!("status",    2)(),
                        PBField!("handle",    3)(),
                        PBField!("size",      4)());

    Type typeId() { return Type.OpenResponse; }
}

class ReadRequest : RPCRequest {
    ushort handle;     // Asset handle to read from
    ulong offset;      // Requested segment start
    uint size;         // Requested segment length
    mixin MessageMixin!(PBField!("rpcId",     1)(),
                        PBField!("handle",    2)(),
                        PBField!("offset",    3)(),
                        PBField!("size",      4)(),
                        PBField!("timeout",   5)());

    Type typeId() { return Type.ReadRequest; }
}

class ReadResponse : RPCResponse {
    Status status;     // Status of request
    ulong offset;      // Returned segment start
    ubyte[] content;   // Returned data
    mixin MessageMixin!(PBField!("rpcId",     1)(),
                        PBField!("status",    2)(),
                        PBField!("offset",    3)(),
                        PBField!("content",   4)());

    Type typeId() { return Type.ReadResponse; }
}

class DataSegment : Message {
    ushort handle;     // Asset handle for the data
    ulong offset;      // Content start offset
    ubyte[] content;   // Content to write
    mixin MessageMixin!(PBField!("handle",    1)(),
                        PBField!("offset",    2)(),
                        PBField!("content",   3)());

    Type typeId() { return Type.DataSegment; }
}

class MetaDataRequest : RPCRequest {
    ushort handle;     // Asset handle for the data
    mixin MessageMixin!(PBField!("rpcId",     1)(),
                        PBField!("handle",    2)(),
                        PBField!("timeout",   3)());

    Type typeId() { return Type.MetaDataRequest; }
}

class MetaDataResponse : RPCResponse {
    Status status;
    Identifier[] ids;
    mixin MessageMixin!(PBField!("rpcId",     1)(),
                        PBField!("status",    2)(),
                        PBField!("ids",       3)());

    Type typeId() { return Type.MetaDataResponse; }
}

class Close : Message {
    ushort handle;     // AssetHandle to release
    mixin MessageMixin!(PBField!("handle",    1)());

    Type typeId() { return Type.Close; }
}
