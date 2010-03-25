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
    uint id;
    char[] name;
    mixin MessageMixin!(PBField!("id",   1)(),
                        PBField!("name", 2)());

    char[] toString() {
        return Format.convert("{} {{\n id: {}\n name: {}\n}}",this.classinfo.name, this.id, this.name);
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
