/*import tango.core.Exception;
import tango.io.Stdout;*/

final class Buffer(T) {
private:
    uint pos;
    T[] buf;
public:
    this() {
        buf = new T[16];
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
alias Buffer!(ubyte) ByteBuffer;

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
            break;
    }
    buf = buf[idx .. length];
    return retval;
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

const PBType PBInt32  = PBType("int",     "enc_varint", "dec_varint", WireType.varint );
const PBType PBsInt32 = PBInt32;
const PBType PBuInt32 = PBType("uint",    "enc_varint", "dec_varint", WireType.varint );
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
    while (i > 0) {
        retval = digits[i%10] ~ retval;
        i /= 10;
    }
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
        retval ~= " enc_varint!(uint)(" ~ protobuf.ItoA((f.id<<3)|cast(uint)f.type.wtype) ~ ", buf);\n";
        retval ~= " " ~ f.type.enc_func ~ "!(" ~ f.type.dtype ~ ")(this." ~ f.name ~ ", buf);\n";
    }
    retval ~= " return buf.data;\n}\n";

    // Create decode-function
    retval ~= "void decode(ubyte[] buf) {\n";
    retval ~= " while (buf.length > 0) {\n  switch (dec_varint!(uint)(buf)) {\n";
    foreach (f; fields) {
        retval ~= "   case " ~ protobuf.ItoA((f.id<<3)|cast(uint)f.type.wtype) ~ ": ";
        retval ~= " this." ~ f.name ~ "=" ~ f.type.dec_func ~"!(" ~ f.type.dtype ~ ")(buf); break;\n";
    }
    retval ~= "  }\n }\n \n}";

    return retval;
}

class Person
{
    const ProtoBufField[] _fields = [
        ProtoBufField(5, "id", PBInt32),
        ProtoBufField(6, "name", PBString),
        ];
//    mixin(MessageMixin("Person", _fields));
int id;
char[] name;
ubyte[] encode(ByteBuffer buf = new ByteBuffer) {
 enc_varint!(uint)(40, buf);
 enc_varint!(int)(this.id, buf);
 enc_varint!(uint)(50, buf);
 enc_wt_ld!(char[])(this.name, buf);
 return buf.data;
}
void decode(ubyte[] buf) {
 while (buf.length > 0) {
  switch (dec_varint!(uint)(buf)) {
   case 40:  this.id=dec_varint!(int)(buf); break;
   case 50:  this.name=dec_wt_ld!(char[])(buf); break;
  }
 }
}

    char[] toString() {
        return this.classinfo.name ~ "{\n id: "~protobuf.ItoA(this.id)~"\n name: "~this.name~"\n}";
    }
}

void main()
{
//    test_varintenc;
//    test_wt_ld_enc;
//    Stdout(MessageMixin("Person", Person._fields)).newline;

    Person x = new Person;
    x.name = "apa";
    x.id = 14;
//    Stdout(x).newline();
    auto bb = new ByteBuffer;
    ubyte[] buf;
    for (int i=0; i < 10000000; i++) {
        bb.reset();
        buf = x.encode(bb);
    }
//    Stdout(buf).newline();
    Person y = new Person;
//    for (int i=0; i < 10000000; i++)
        y.decode(buf);
//    Stdout(y).newline();
}
/*
bool test_varintenc() {
    Stdout("Testing varint_enc... ");
    uint i;
    try {
        for (i=0; i < 500000; i+=17) {
            auto middle = new ByteBuffer;
            enc_varint(i, middle);
            auto data = middle.data;
            uint roundtrip = dec_varint!(uint)(data);
            if (i == roundtrip) {
                version (Debug) Stdout.format("{} == {} (middle: {})", i, roundtrip, middle).newline;
            } else {
                version (Debug) Stdout.format("{} != {} (middle: {})", i, roundtrip, middle).newline;
                throw new AssertException("Varint_test failed", __LINE__);
            }
        }
        Stdout("[PASS]").newline;
        return true;
    } catch (Exception e) {
        Stdout.format("[FAIL] (on {})", i).newline;
        throw e;
    }
}

bool test_wt_ld_enc() {
    Stdout("Testing wt_ld_codec... ");
    ubyte[] testdata = cast(ubyte[])"abcdefgh\0andthensome";
    try {
        auto middle = new ByteBuffer;
        enc_wt_ld(testdata, middle);
        auto data = middle.data;
        ubyte[] roundtrip = dec_wt_ld!(ubyte[])(data);
        if (testdata == roundtrip) {
            version (Debug) Stdout.format("{} == {} (middle: {})", testdata, roundtrip, middle).newline;
        } else {
            version (Debug) Stdout.format("{} != {} (middle: {})", testdata, roundtrip, middle).newline;
            throw new AssertException("wt_ld_codec failed", __LINE__);
        }
        Stdout("[PASS]").newline;
        return true;
    } catch (Exception e) {
        Stdout.format("[FAIL] (on {})", testdata).newline;
        throw e;
    }
}
*/