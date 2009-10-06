module lib.protobuf;

/**
 * Buffer implementation designed to be filled BACKWARDS, to increase performance of prefix-length encoding.
 */
final class PBuffer(T) {
private:
    uint pos;
    T[] buf;
public:
    this(uint size = 16) {
        buf = new T[size];
        pos = size;
    }
    T[] data() {
        return buf[pos .. length];
    }
    T[] alloc(uint size) {
        int newpos = pos - size;
        if (newpos < 0) {
            auto newbuf = new T[buf.length + size];
            auto resize = newbuf.length - buf.length;
            newbuf[length-(buf.length-pos)..length] = buf[pos..length];
            delete buf;
            newpos += resize;
            pos += resize;
            buf = newbuf;
        }
        return buf[newpos..pos];
    }
    void charge(uint size) {
        pos -= size;
    }
    void prepend(T[] data) {
        alloc(data.length)[] = data;
        charge(data.length);
    }
    void reset() {
        pos = buf.length;
    }
    size_t length() {
        return buf.length-pos;
    }
}
alias PBuffer!(ubyte) ByteBuffer;

void enc_wt_ld(T)(T value, ByteBuffer buf) {
    buf.prepend(cast(ubyte[])value);
    enc_varint(value.length, buf);
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
    auto maxbits = 0;
    auto x = i;
    while (x) {
        maxbits += 7;
        x >>= 7;
    }
    auto encbytes = (maxbits/8)+1;
    auto slice = buffer.alloc(encbytes);
    foreach (ref b; slice) {
        b = i | 0b10000000;
        i >>= 7;
    }
    slice[length-1] &= 0b01111111;
    buffer.charge(encbytes);
}

T dec_varint(T)(ref ubyte[] buf) {
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
    retval ~= "final ubyte[] encode(ByteBuffer buf = new ByteBuffer) { \n";
    foreach (f; fields) {
        retval ~= " " ~ f.type.enc_func ~ "!(" ~ f.type.dtype ~ ")(this." ~ f.name ~ ", buf);\n";
        retval ~= " enc_varint!(uint)(" ~ lib.protobuf.ItoA((f.id<<3)|cast(uint)f.type.wtype) ~ ", buf);\n";
    }
    retval ~= " return buf.data;\n}\n";

    // Create decode-function
    retval ~= "final void decode(ubyte[] buf) {\n";
    retval ~= " while (buf.length > 0) {\n  switch (dec_varint!(uint)(buf)) {\n";
    foreach (f; fields) {
        retval ~= "   case " ~ lib.protobuf.ItoA((f.id<<3)|cast(uint)f.type.wtype) ~ ": ";
        retval ~= "    this." ~ f.name ~ "=" ~ f.type.dec_func ~"!(" ~ f.type.dtype ~ ")(buf); break;\n";
    }
    retval ~= "  }\n }\n \n}";

    return retval;
}
