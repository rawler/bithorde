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
        ProtoBufField(1, "type",    PBInt8),    // Type of message
        ProtoBufField(2, "id",      PBuInt8),   // Local-link-id of message
        ProtoBufField(4, "content", PBBytes),   // Content of message
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

class BHOpenRequest : ProtoBufMessage {
    const ProtoBufField[] _fields = [
        ProtoBufField(11, "priority", PBuInt8), // Priority of this request
        ProtoBufField(12, "hash", PBuInt8),     // Hash-domain to look in
        ProtoBufField(13, "id", PBBytes),       // ID of object requested
    ];
    mixin(MessageMixin("BitHordeMessage.OpenRequest", _fields));
}

class BHOpenResponse : ProtoBufMessage {
    const ProtoBufField[] _fields = [
        ProtoBufField(21, "handle", PBuInt16),  // Handle to object, 0 means failure
        ProtoBufField(22, "distance", PBuInt8), // How fast will we be able to deliver on this?
        ProtoBufField(23, "size", PBuInt8),     // Size of object
    ];
    mixin(MessageMixin("BitHordeMessage.OpenResponse", _fields));
}

class BHCloseRequest : ProtoBufMessage{
    const ProtoBufField[] _fields = [
        ProtoBufField(21, "handle", PBuInt16),  // Handle of file to be closed
    ];
    mixin(MessageMixin("BitHordeMessage.CloseRequest", _fields));
}

