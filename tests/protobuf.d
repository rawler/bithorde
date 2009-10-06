module tests.protobuf;

private import tango.core.Exception;
private import tango.io.Stdout;

import lib.protobuf;

class Person
{
    const ProtoBufField[] _fields = [
        ProtoBufField(5, "id", PBInt32),
        ProtoBufField(6, "name", PBString),
        ];
    mixin(MessageMixin("Person", _fields));

    char[] toString() {
        return this.classinfo.name ~ "{\n id: "~lib.protobuf.ItoA(this.id)~"\n name: "~this.name~"\n}";
    }

    bool opEquals(Person other) {
        return (this.id == other.id) &&
               (this.name == other.name);
    }
}

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
                debug (protobuf) Stdout.format("{} == {} (middle: {})", i, roundtrip, middle).newline;
            } else {
                debug (protobuf) Stdout.format("{} != {} (middle: {})", i, roundtrip, middle).newline;
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
            debug (protobuf) Stdout.format("{} == {} (middle: {})", testdata, roundtrip, middle).newline;
        } else {
            debug (protobuf) Stdout.format("{} != {} (middle: {})", testdata, roundtrip, middle).newline;
            throw new AssertException("wt_ld_codec failed", __LINE__);
        }
        Stdout("[PASS]").newline;
        return true;
    } catch (Exception e) {
        Stdout.format("[FAIL] (on {})", testdata).newline;
        throw e;
    }
}

bool test_object_enc()
{
    Stdout ("Testing Object-Encoding...");
    debug (protobuf) Stdout(MessageMixin("Person", Person._fields)).newline;
    Person x = new Person;
    x.name = "apa";
    x.id = 14;
    debug (protobuf) Stdout(x).newline();
    auto bb = new ByteBuffer;
    ubyte[] buf;
    buf = x.encode(bb);
    debug (protobuf) Stdout(buf).newline();
    Person y = new Person;
    y.decode(buf);
    debug (protobuf) Stdout(y).newline();
    if (x == y) {
        Stdout("[PASS]").newline;
        return true;
    } else {
        Stdout("[FAIL]").newline;
        return false;
    }
}

void main()
{
    test_varintenc;
    test_wt_ld_enc;
    test_object_enc;
}
