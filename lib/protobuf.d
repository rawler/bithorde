module lib.protobuf;

final class PBuffer(T) {
private:
    uint pos;
    T[] buf;
public:
    this(uint size = 16) {
        buf = new T[size];
    }
    T[] data() {
        return buf[0 .. pos];
    }
    T[] alloc(uint size) {
        auto newpos = pos + size;
        if (newpos > buf.length)
            buf.length = buf.length*2 + size;
        return buf[pos..newpos];
    }
    void charge(uint size) {
        pos += size;
    }
    void append(T[] data) {
        alloc(data.length)[] = data;
        charge(data.length);
    }
    void reset() {
        pos = 0;
    }
}
alias PBuffer!(ubyte) ByteBuffer;

void enc_wt_ld(T)(T value, ByteBuffer buf) {
    enc_varint(value.length, buf);
    buf.append(cast(ubyte[])value);
}

T dec_wt_ld(T)(ref ubyte[] buf) {
    auto vlen = dec_varint!(uint)(buf);
    T retval = cast(T)buf[0 .. vlen];
    buf = buf[vlen .. length];
    return retval;
}

interface ProtoBufMessage {
    ubyte[] encode(ByteBuffer buf = new ByteBuffer);
    void decode(ubyte[] buf);
}

void enc_varint(T)(T i, ByteBuffer buffer) {
    ubyte idx;
    auto buf = buffer.alloc((T.sizeof*8)/7 + 1);
    do
    {
        ubyte current = i & 0b01111111;
        i >>= 7;
        if (i) {
            buf[idx++] = current | 0b10000000;
        } else {
            buf[idx++] = current;
            break;
        }
    } while (i)
    buffer.charge(idx);
}

T dec_varint(T)(ref ubyte[] buf) {
    uint base = 1;
    T retval = 0;
    uint idx = 0;
    foreach (b; buf) {
        retval ^= cast(uint)(b & 0b01111111) << (idx++*7);
        if (!(b & 0b10000000))
        {
            buf = buf[idx .. length];
            return retval;
        }
    }
    return 0;
}

enum WireType {
    varint = 0,
    fixed64 = 1,
    length_delim = 2,
    fixed32 = 5,
}

struct PBType {
    char[] dtype;
    char[] enc_func;
    char[] dec_func;
    WireType wtype;
};

const PBType PBInt8   = PBType("byte",    "enc_varint", "dec_varint", WireType.varint );
const PBType PBuInt8  = PBType("ubyte",   "enc_varint", "dec_varint", WireType.varint );
const PBType PBInt16  = PBType("short",   "enc_varint", "dec_varint", WireType.varint );
const PBType PBuInt16 = PBType("ushort",  "enc_varint", "dec_varint", WireType.varint );
const PBType PBInt32  = PBType("int",     "enc_varint", "dec_varint", WireType.varint );
const PBType PBuInt32 = PBType("uint",    "enc_varint", "dec_varint", WireType.varint );
const PBType PBInt64  = PBType("long",    "enc_varint", "dec_varint", WireType.varint );
const PBType PBuInt64 = PBType("ulong",   "enc_varint", "dec_varint", WireType.varint );
const PBType PBBool   = PBType("bool",    "enc_varint", "dec_varint", WireType.varint );
const PBType PBString = PBType("char[]",  "enc_wt_ld" , "dec_wt_ld" , WireType.length_delim );
const PBType PBBytes  = PBType("ubyte[]", "enc_wt_ld" , "dec_wt_ld" , WireType.length_delim );

struct ProtoBufField {
    uint id;
    char[] name;
    PBType type;
};

char[] ItoA(uint i) {
    char[] digits = "0123456789";
    char[] retval;
    do {
        retval = digits[i%10] ~ retval;
        i /= 10;
    } while (i > 0)
    return retval;
}

char[] MessageMixin(char[] name, ProtoBufField fields[]) {
    char[] retval = "";
    // Declare members
    foreach (f; fields) {
        retval ~= f.type.dtype ~ " " ~ f.name ~ ";\n";
    }

    // Create encode-function
    retval ~= "ubyte[] encode(ByteBuffer buf = new ByteBuffer) { \n";
    foreach (f; fields) {
        retval ~= " enc_varint!(uint)(" ~ lib.protobuf.ItoA((f.id<<3)|cast(uint)f.type.wtype) ~ ", buf);\n";
        retval ~= " " ~ f.type.enc_func ~ "!(" ~ f.type.dtype ~ ")(this." ~ f.name ~ ", buf);\n";
    }
    retval ~= " return buf.data;\n}\n";

    // Create decode-function
    retval ~= "void decode(ubyte[] buf) {\n";
    retval ~= " while (buf.length > 0) {\n  switch (dec_varint!(uint)(buf)) {\n";
    foreach (f; fields) {
        retval ~= "   case " ~ lib.protobuf.ItoA((f.id<<3)|cast(uint)f.type.wtype) ~ ": ";
        retval ~= "    this." ~ f.name ~ "=" ~ f.type.dec_func ~"!(" ~ f.type.dtype ~ ")(buf); break;\n";
    }
    retval ~= "  }\n }\n \n}";

    return retval;
}
