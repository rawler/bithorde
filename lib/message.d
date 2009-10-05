module lib.message;

private import tango.core.Exception;
private import tango.core.Memory;
private import tango.io.Stdout;

private import lib.protobuf;

public class BitHordeMessage : ProtoBufMessage {
private:
    static BitHordeMessage _freeList;
    static uint alloc, reuse;
    BitHordeMessage _next;
    new(size_t sz)
    {
        BitHordeMessage m;

        if (_freeList) {
            m = _freeList;
            _freeList = m._next;
            reuse++;
        } else {
            m = cast(BitHordeMessage)GC.malloc(sz);
            alloc++;
        }
        return cast(void*)m;
    }
    delete(void * p)
    {
        auto m = cast(BitHordeMessage)p;
        m._next = _freeList;
        _freeList = m;
    }
public:
    enum Type
    {
        OpenRequest = 2,
        OpenResponse = 3,
        CloseRequest = 4,
        CloseResponse = 5,
        ReadRequest = 6,
        ReadResponse = 7,
    }

    enum HashType
    {
        MD5 = 1,
        SHA1 = 2,
        SHA256 = 3,
    }

    enum Status {
        SUCCESS = 1,
        NOTFOUND = 2,
        INVALID_HANDLE = 3,
        WOULD_LOOP = 4,
    }

    const ProtoBufField[] _fields = [
        ProtoBufField(0,  "type",      PBuInt8), // Type of message
        ProtoBufField(1,  "id",        PBuInt8), // Local-link-id of message
        ProtoBufField(2,  "status",    PBuInt8), // Did some error occurr?
        ProtoBufField(3,  "priority",  PBuInt8), // Priority of this request
        ProtoBufField(4,  "content",   PBBytes), // Content of message
        ProtoBufField(5,  "hashtype",  PBuInt8), // Hash-domain to look in
        ProtoBufField(6,  "distance",  PBuInt8), // How fast will we be able to deliver on this?
        ProtoBufField(7,  "size",     PBuInt64), // Size of asset
        ProtoBufField(8,  "handle",   PBuInt16), // Handle to asset, 0 means failure
        ProtoBufField(9,  "offset",   PBuInt64), // Start reading from where?
        ];
    mixin(MessageMixin("BitHordeMessage", _fields));

    char[] toString() {
        auto retval = "<BitHordeMessage type: " ~ ItoA(type) ~ " id: " ~ ItoA(id);
        if (this.content)
            retval ~= " content.length: " ~ ItoA(content.length);
        return retval ~ ">";
    }

    bool isResponse() {
        return cast(bool)(this.type & 1);
    }
}
alias BitHordeMessage.Status BHStatus;

