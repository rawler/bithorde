module lib.message;

private import lib.protobuf;

public class BitHordeMessage : ProtoBufMessage {
    enum Type
    {
        KeepAlive = 0,
        Error = 1,
        OpenRequest = 2,
        OpenResponse = 3,
        CloseRequest = 4,
        ReadRequest = 6,
        ReadResponse = 7,
    }

    enum HashType
    {
        MD5 = 1,
        SHA1 = 2,
        SHA256 = 3,
    }

    const ProtoBufField[] _fields = [
        ProtoBufField(0,  "type",      PBuInt8), // Type of message
        ProtoBufField(1,  "id",        PBuInt8), // Local-link-id of message
        ProtoBufField(2,  "priority",  PBuInt8), // Priority of this request
        ProtoBufField(3,  "content",   PBBytes), // Content of message
        ProtoBufField(4,  "hashtype",  PBuInt8), // Hash-domain to look in
        ProtoBufField(5,  "distance",  PBuInt8), // How fast will we be able to deliver on this?
        ProtoBufField(6,  "size",     PBuInt64), // Size of asset
        ProtoBufField(7,  "handle",   PBuInt16), // Handle to asset, 0 means failure
        ProtoBufField(8,  "offset",   PBuInt64), // How fast will we be able to deliver on this?
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
