module lib.message;

private import tango.core.Exception;
private import tango.core.Memory;
private import tango.io.Stdout;
private import tango.util.container.more.Stack;

private import lib.protobuf;

enum Type
{
    OpenRequest = 2,
    OpenResponse = 3,
    Close = 4,
    ReadRequest = 5,
    ReadResponse = 6,
}

public abstract class Message : ProtoBufMessage {
private:
    static Stack!(void*, 100) _freeList;
    new(size_t sz) {
        if (_freeList.size)
            return _freeList.pop();
        else
            return GC.malloc(128);
    }
    delete(void * p) {
        if (_freeList.unused)
            _freeList.push(p);
        else
            GC.free(p);
    }
protected:
public:
    abstract Type typeId();
    abstract bool isResponse();
}

abstract class RPCMessage : Message {
    abstract ushort rpcId();
    abstract void rpcId(ushort val);
    template Mixin() {
        final ushort rpcId() { return reqId; }
        final void rpcId(ushort val) { reqId = val; }
    }
}

abstract class RPCRequest : RPCMessage {
    final bool isResponse() { return false; }
}

abstract class RPCResponse : RPCMessage {
    final bool isResponse() { return true; }
    RPCRequest request;
    ~this() {
        if (request)
            delete request;
    }
}

enum HashType
{
    MD5 = 1,
    SHA1 = 2,
    SHA256 = 3,
}
const PBType PBHashType = PBType("HashType",  "enc_varint", "dec_varint", WireType.varint );

enum Status {
    SUCCESS = 1,
    NOTFOUND = 2,
    INVALID_HANDLE = 3,
    WOULD_LOOP = 4,
}
const PBType PBStatus = PBType("Status",  "enc_varint", "dec_varint", WireType.varint );

private import lib.asset;

/****** Start defining the messages *******/

class OpenRequest : RPCRequest {
    const ProtoBufField[] _fields = [
        ProtoBufField(1,  "reqId",    PBuInt16), // Local-link-request id
        ProtoBufField(2,  "hashType", PBHashType), // Hash-domain to look in
        ProtoBufField(3,  "assetId",   PBBytes), // AssetId
        ProtoBufField(4,  "uuid",     PBuInt64), // UUID to avoid loops
        ];
    mixin(MessageMixin(_fields));

    Type typeId() { return Type.OpenRequest; }
    mixin RPCMessage.Mixin;

    BHOpenCallback callback;
}

class OpenResponse : RPCResponse {
    const ProtoBufField[] _fields = [
        ProtoBufField(1,  "reqId",    PBuInt16), // Local-link-request id
        ProtoBufField(2,  "status",   PBStatus), // Status of request
        ProtoBufField(3,  "handle",   PBuInt16), // Assigned handle
        ProtoBufField(4,  "size",     PBuInt64), // Size of opened asset
        ];
    mixin(MessageMixin(_fields));

    Type typeId() { return Type.OpenResponse; }
    mixin RPCMessage.Mixin;
}

class ReadRequest : RPCRequest {
    const ProtoBufField[] _fields = [
        ProtoBufField(1,  "reqId",    PBuInt16), // Local-link-request id
        ProtoBufField(2,  "handle",   PBuInt16), // Asset handle to read from
        ProtoBufField(3,  "offset",   PBuInt64), // Requested segment start
        ProtoBufField(4,  "size",     PBuInt32), // Requested segment length
        ];
    mixin(MessageMixin(_fields));

    Type typeId() { return Type.ReadRequest; }
    mixin RPCMessage.Mixin;

    BHReadCallback callback;
}

class ReadResponse : RPCResponse {
    const ProtoBufField[] _fields = [
        ProtoBufField(1,  "reqId",    PBuInt16), // Local-link-request id
        ProtoBufField(2,  "status",   PBStatus), // Status of request
        ProtoBufField(3,  "offset",   PBuInt64), // Returned segment start
        ProtoBufField(4,  "content",   PBBytes), // Returned data
        ];
    mixin(MessageMixin(_fields));

    Type typeId() { return Type.ReadResponse; }
    mixin RPCMessage.Mixin;
}

class Close : Message {
    const ProtoBufField[] _fields = [
        ProtoBufField(1,  "handle",   PBuInt16), // AssetHandle to release
        ];
    mixin(MessageMixin(_fields));

    Type typeId() { return Type.Close; }
    bool isResponse() { return false; }
}
