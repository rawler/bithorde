/****************************************************************************************
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
module tests.protobuf;

private import tango.core.Exception;
private import tango.io.Stdout;
private import tango.text.convert.Format;

import lib.protobuf;

class Person : ProtoBufMessage
{
    mixin(PBField!(uint,"id"));
    mixin(PBField!(char[],"name"));
    mixin ProtoBufCodec!(PBMapping("id",       1),
                         PBMapping("name",     2));

    char[] toString() {
        return Format.convert("{} {{\n id: {}\n name: {}\n}}",this.classinfo.name, this.id, this.name);
    }

    bool opEquals(Person other) {
        return (this.id == other.id) &&
               (this.name == other.name);
    }
}

class Person2 : ProtoBufMessage
{
    mixin(PBField!(uint, "id"));
    mixin(PBField!(char[], "name"));
    mixin(PBField!(char[], "addr"));
    mixin ProtoBufCodec!(PBMapping("id",   1),
                         PBMapping("name", 2),
                         PBMapping("addr", 3));
    bool opEquals(Person other) {
        return (this.id == other.id) &&
               (this.name == other.name);
    }
}

class Friends : ProtoBufMessage
{
    mixin(PBField!(Person[],"people"));
    mixin ProtoBufCodec!(PBMapping("people", 1));

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

void runtestlist(TYPE)(ubyte[][TYPE] list) {
    foreach (orig,v; list) {
        auto middle = new ByteBuffer;
        encode_val(orig, middle);
        auto data = middle.data;
        if (data != v)
            throw new AssertException(TYPE.stringof ~ "test failed", __LINE__);
        TYPE roundtrip;
        if (decode_val(data, roundtrip) && (orig == roundtrip)) {
            debug (protobuf) Stdout.format("{} == {} (middle: {})", orig, roundtrip, middle).newline;
        } else {
            debug (protobuf) Stdout.format("{} != {} (middle: {})", orig, roundtrip, middle).newline;
            throw new AssertException(TYPE.stringof ~ "test failed", __LINE__);
        }
    }
}

bool test_varintenc() {
    Stdout("Testing varint encoding... ");

    ubyte[][uint] uintlist;
    uintlist[0] =   cast(ubyte[])[0];
    uintlist[1] =   cast(ubyte[])[1];
    uintlist[127] = cast(ubyte[])[127];
    uintlist[300] = cast(ubyte[])[172, 2];
    uintlist[128] = cast(ubyte[])[128, 1];
    uintlist[4294967280] = cast(ubyte[])[240, 255, 255, 255, 15];
    runtestlist(uintlist);

    ubyte[][ulong] ulonglist;
    ulonglist[0] =   cast(ubyte[])[0];
    ulonglist[1] =   cast(ubyte[])[1];
    ulonglist[127] = cast(ubyte[])[127];
    ulonglist[300] = cast(ubyte[])[172, 2];
    ulonglist[128] = cast(ubyte[])[128, 1];
    ulonglist[4294967280] = cast(ubyte[])[240, 255, 255, 255, 15];
    ulonglist[8589934560] = cast(ubyte[])[224, 255, 255, 255, 31];
    runtestlist(ulonglist);

    ubyte[][int] intlist;
    intlist[-2147483640] = cast(ubyte[])[239, 255, 255, 255, 15];
    intlist[-150] = cast(ubyte[])[171, 2];
    intlist[-64] =  cast(ubyte[])[127];
    intlist[-3] =   cast(ubyte[])[5];
    intlist[-2] =   cast(ubyte[])[3];
    intlist[-1] =   cast(ubyte[])[1];
    intlist[0] =    cast(ubyte[])[0];
    intlist[1] =    cast(ubyte[])[2];
    intlist[2] =    cast(ubyte[])[4];
    intlist[3] =    cast(ubyte[])[6];
    intlist[64] =   cast(ubyte[])[128,1];
    intlist[150] =  cast(ubyte[])[172, 2];
    intlist[2147483640] = cast(ubyte[])[240, 255, 255, 255, 15];
    runtestlist(intlist);

    ubyte[][long] longlist;
    longlist[-4294967280] = cast(ubyte[])[223, 255, 255, 255, 31];
    longlist[-2147483640] = cast(ubyte[])[239, 255, 255, 255, 15];
    longlist[-150] = cast(ubyte[])[171, 2];
    longlist[-64] = cast(ubyte[])[127];
    longlist[-2] =  cast(ubyte[])[3];
    longlist[-1] =  cast(ubyte[])[1];
    longlist[0] =   cast(ubyte[])[0];
    longlist[1] =   cast(ubyte[])[2];
    longlist[2] =   cast(ubyte[])[4];
    longlist[64] =  cast(ubyte[])[128,1];
    longlist[150] =  cast(ubyte[])[172, 2];
    longlist[2147483640] = cast(ubyte[])[240, 255, 255, 255, 15];
    longlist[4294967280] = cast(ubyte[])[224, 255, 255, 255, 31];
    runtestlist(longlist);

    Stdout("[PASS]").newline;
    return true;
}

bool test_wt_ld_enc() {
    Stdout("Testing wt_ld_codec... ");
    ubyte[] testdata = cast(ubyte[])"abcdefgh\0andthensome";
    try {
        auto middle = new ByteBuffer;
        encode_val(testdata, middle);
        auto data = middle.data;
        ubyte[] roundtrip;
        if (decode_val!(ubyte[])(data, roundtrip) && (testdata == roundtrip)) {
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
    x.people = [onlyFriend, onlyFriend, onlyFriend];
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

bool test_skip_unknown()
{
    Stdout ("Testing Forward-Compatibility by skipping unknown attributes...");
    auto newVersionFriend = new Person2;
    newVersionFriend.name = "arne";
    newVersionFriend.id = 5;
    newVersionFriend.addr = "Experimental Street 1";
    auto bb = new ByteBuffer;
    auto buf = newVersionFriend.encode(bb);
    debug (protobuf) Stdout(buf).newline();
    Person y = new Person;
    y.decode(buf);
    if (newVersionFriend == y) {
        Stdout("[PASS]").newline;
        return true;
    } else {
        Stdout("[FAIL]").newline;
        return false;
    }
}

bool test_unset()
{
    Stdout ("Testing IsSet-functionality...");
    auto a = new Person;
    a.name = "arne";
    assert(!a.idIsSet, "Id should not be marked as set");
    auto bb = new ByteBuffer;
    auto buf = a.encode(bb);
    debug (protobuf) Stdout(buf).newline();
    Person b = new Person;
    b.decode(buf);
    assert(!b.idIsSet, "Id should still not be marked as set");
    b.id = 5;
    assert(b.idIsSet, "Id should now be marked as set");
    buf = b.encode(bb);
    a = new Person;
    a.decode(buf);
    if (a.idIsSet) {
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
    test_skip_unknown;
    test_unset;
}
