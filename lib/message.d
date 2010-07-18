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
    BindRead = 2,
    AssetStatus = 3,
    ReadRequest = 5,
    ReadResponse = 6,
    BindWrite = 7,
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
        assert(sz <= 200, "Error, allocating too much");
        synchronized (listMutex) {
            if (_freeList.size)
                return _freeList.pop();
        } // Else
        return GC.malloc(200);
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
    NORESOURCES = 7,
    ERROR = 8,
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
        "NORESOURCES",
        "ERROR",
    ];
    if (s >= _map.length)
        return "<unknown>";
    else
        return _map[s];
}

abstract class RPCMessage : Message {
    mixin(PBField!(ushort, "rpcId"));    // Local-link request id
}

abstract class RPCRequest : RPCMessage {
    mixin(PBField!(ushort, "timeout"));
    abstract void abort(Status s);
}

abstract class RPCResponse : RPCMessage {
    RPCRequest request;
}

private import lib.asset;

/****** Start defining the messages *******/
class Identifier : ProtoBufMessage {
    this(HashType t, ubyte[] id) {
        this.type = t;
        this.id = id;
    }
    this() {}
    mixin(PBField!(HashType, "type"));
    mixin(PBField!(ubyte[], "id"));
    mixin ProtoBufCodec!(PBMapping("type", 1),
                         PBMapping("id",   2));
    /************************************************************************************
     * Return new deep-copied instance of the Identifier
     ***********************************************************************************/
    Identifier dup() {
        return new Identifier(type, id.dup);
    }
}

class HandShake : Message {
    mixin(PBField!(char[], "name"));
    mixin(PBField!(ubyte, "protoversion"));
    mixin ProtoBufCodec!(PBMapping("name", 1),
                         PBMapping("protoversion", 2));
    Type typeId() { return Type.HandShake; }
}

package class BindRequest : Message {
    mixin(PBField!(ushort, "handle"));     // Requested handle
    mixin(PBField!(ushort, "timeout"));    // Timeout
}

class BindRead : BindRequest {
    mixin(PBField!(Identifier[], "ids"));  // Asset-Id:s to look for
    mixin(PBField!(ulong, "uuid"));        // UUID to avoid loops

    mixin ProtoBufCodec!(PBMapping("handle",   1),
                         PBMapping("ids",      2),
                         PBMapping("uuid",     3),
                         PBMapping("timeout",  4));

    Type typeId() { return Type.BindRead; }
}

class BindWrite : BindRequest {
    mixin(PBField!(ulong, "size"));        // Size of opened asset
    mixin ProtoBufCodec!(PBMapping("handle",   1),
                         PBMapping("size",     2),
                         PBMapping("timeout",  3));

    Type typeId() { return Type.BindWrite; }
}

class AssetStatus : Message {
    mixin(PBField!(ushort, "handle"));     // Requested handle
    mixin(PBField!(Status, "status"));     // Status of request
    mixin(PBField!(ulong, "size"));        // Size of opened asset
    mixin ProtoBufCodec!(PBMapping("handle",    1),
                         PBMapping("status",    2),
                         PBMapping("size",      4));

    Type typeId() { return Type.AssetStatus; }
}

class ReadRequest : RPCRequest {
    mixin(PBField!(ushort, "handle"));     // Asset handle to read from
    mixin(PBField!(ulong, "offset"));      // Requested segment start
    mixin(PBField!(uint, "size"));         // Requested segment length
    mixin ProtoBufCodec!(PBMapping("rpcId",     1),
                         PBMapping("handle",    2),
                         PBMapping("offset",    3),
                         PBMapping("size",      4),
                         PBMapping("timeout",   5));

    Type typeId() { return Type.ReadRequest; }
}

class ReadResponse : RPCResponse {
    mixin(PBField!(Status, "status"));     // Status of request
    mixin(PBField!(ulong, "offset"));      // Returned segment start
    mixin(PBField!(ubyte[], "content"));   // Returned data
    mixin ProtoBufCodec!(PBMapping("rpcId",     1),
                         PBMapping("status",    2),
                         PBMapping("offset",    3),
                         PBMapping("content",   4));

    Type typeId() { return Type.ReadResponse; }
}

class DataSegment : Message {
    mixin(PBField!(ushort, "handle"));     // Asset handle for the data
    mixin(PBField!(ulong, "offset"));      // Content start offset
    mixin(PBField!(ubyte[], "content"));   // Content to write
    mixin ProtoBufCodec!(PBMapping("handle",    1),
                         PBMapping("offset",    2),
                         PBMapping("content",   3));

    Type typeId() { return Type.DataSegment; }
}

class MetaDataRequest : RPCRequest {
    mixin(PBField!(ushort, "handle"));     // Asset handle for the data
    mixin ProtoBufCodec!(PBMapping("rpcId",     1),
                         PBMapping("handle",    2),
                         PBMapping("timeout",   3));

    Type typeId() { return Type.MetaDataRequest; }
}

class MetaDataResponse : RPCResponse {
    mixin(PBField!(Status, "status"));
    mixin(PBField!(Identifier[], "ids"));
    mixin ProtoBufCodec!(PBMapping("rpcId",     1),
                         PBMapping("status",    2),
                         PBMapping("ids",       3));

    Type typeId() { return Type.MetaDataResponse; }
}
