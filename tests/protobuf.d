module tests.protobuf;

private import tango.core.Exception;
private import tango.io.Stdout;

import lib.protobuf;

class Person : ProtoBufMessage
{
    uint id;
    char[] name;
    mixin MessageMixin!(PBField!("id",   1)(),
                        PBField!("name", 2)());

    char[] toString() {
        return this.classinfo.name ~ "{\n id: "~lib.protobuf.ItoA(this.id)~"\n name: "~this.name~"\n}";
    }

    bool opEquals(Person other) {
        return (this.id == other.id) &&
               (this.name == other.name);
    }
}

class Friends : ProtoBufMessage
{
    Person[] people;
    mixin MessageMixin!(PBField!("people", 1)());

    char[] toString() {
        auto retval = this.classinfo.name ~ "{\n people: [\n";
        foreach (friend; people)
            retval ~= friend.toString() ~ ",\n";
        return retval ~ "]}";
    }

    bool opEquals(Friends other) {
        if (this.people.length != other.people.length)
            return false;
        for (int i=0; i < people.length; i++) {
            if (this.people[i] != other.people[i])
                return false;
        }
        return true;
    }
}

bool test_varintenc() {
    Stdout("Testing varint_enc... ");
    uint i;
    try {
        for (i=0; i < 500000; i+=17) {
            auto middle = new ByteBuffer;
            encode_val(i, middle);
            auto data = middle.data;
            uint roundtrip = decode_val!(uint)(data);
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
        encode_val(testdata, middle);
        auto data = middle.data;
        ubyte[] roundtrip = decode_val!(ubyte[])(data);
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

bool test_repeated_enc()
{
    Stdout ("Testing Repeated Embedded Object-Encoding...");
    auto onlyFriend = new Person;
    onlyFriend.name = "arne";
    onlyFriend.id = 5;
    Friends x = new Friends;
    x.people ~= onlyFriend;
    x.people ~= onlyFriend;
    x.people ~= onlyFriend;
    debug (protobuf) Stdout(x).newline();
    auto bb = new ByteBuffer;
    ubyte[] buf;
    buf = x.encode(bb);
    debug (protobuf) Stdout(buf).newline();
    Friends y = new Friends;
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
    test_repeated_enc;
}
