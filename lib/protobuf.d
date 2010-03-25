/****************************************************************************************
 * D template-based implementation of Protocol Buffers. Built for efficency and high
 * performance rather than flexibility or completeness.
 *
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
module lib.protobuf;

/****************************************************************************************
 * Buffer implementation designed to be filled BACKWARDS, to increase performance of
 * prefix-length encodings.
 ***************************************************************************************/
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

interface ProtoBufMessage {
    ubyte[] encode(ByteBuffer buf = new ByteBuffer);
    void decode(ubyte[] buf);
}

/// Basic Types
enum WireType {
    varint = 0,
    fixed64 = 1,
    length_delim = 2,
    fixed32 = 5,
}

void encode_val(T : ubyte[])(T value, ByteBuffer buf) {
    buf.prepend(cast(ubyte[])value);
    encode_val(value.length, buf);
}

T decode_val(T : ubyte[])(ref ubyte[] buf) {
    uint vlen = decode_val!(uint)(buf);
    assert(buf.length >= vlen);
    auto retval = cast(T)buf[0 .. vlen];
    buf = buf[vlen .. length];
    return retval;
}

void encode_val(T : long)(T i, ByteBuffer buffer) {
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

T decode_val(T : long)(ref ubyte[] buf) {
    T retval = cast(T)0;
    uint idx = 0;
    foreach (b; buf) {
        retval ^= cast(T)(b & 0b01111111) << (idx++*7);
        if (!(b & 0b10000000))
        {
            buf = buf[idx .. length];
            return retval;
        }
    }
    return T.init;
}

struct PBField(char[] _name, uint _id) {
    char[] name = _name;
    uint id = _id;
    static if ( is( typeof(mixin(_name)) : int) )
        WireType wType = WireType.varint;
    else
        WireType wType = WireType.length_delim;
};

public {
    void write(T:int)(uint descriptor, T value, ByteBuffer buf) {
        encode_val(value, buf);
        encode_val(descriptor, buf);
    }
    void write(T:ubyte[])(uint descriptor, T value, ByteBuffer buf) {
        encode_val(value, buf);
        encode_val(descriptor, buf);
    }
    void write(T:ProtoBufMessage)(uint descriptor, T value, ByteBuffer buf) {
        auto start = buf.length;
        value.encode(buf);  // Encode the message to the buffer
        encode_val(buf.length - start, buf); // Write the length of the message to the buffer
        encode_val(descriptor, buf);
    }
    void write(T:ProtoBufMessage)(uint descriptor, T[] values, ByteBuffer buf) {
        foreach_reverse(value; values)
            write(descriptor, value, buf);
    }

    void read(T:int)(ref T member, ref ubyte[] buf) {
        member = decode_val!(T)(buf);
    }
    void read(T:ubyte[])(ref T member, ref ubyte[] buf) {
        member = decode_val!(T)(buf);
    }
    void read(T:ProtoBufMessage)(ref T member, ref ubyte[] buf) {
        member = new T;
        auto msglen = decode_val!(uint)(buf);
        member.decode(buf[0..msglen]);
        buf = buf[msglen..length];
    }
    void read(T:ProtoBufMessage)(ref T[] members, ref ubyte[] buf) {
        auto t = new T;
        auto msglen = decode_val!(uint)(buf);
        t.decode(buf[0..msglen]);
        members ~= t;
        buf = buf[msglen..length];
    }
}

template MessageMixin(fields...) {
    final ubyte[] encode(ByteBuffer buf = new ByteBuffer) {
        foreach_reverse (int i, f; fields)
            write((fields[i].id<<3) | fields[i].wType,
                  mixin("this."~fields[i].name), buf);
        return buf.data;
    }

    final void decode(ubyte[] buf) {
        while (buf.length > 0) {
            auto descriptor = decode_val!(uint)(buf);
            switch (descriptor) {
                foreach (int i, f; fields) {
                    case (fields[i].id<<3)|fields[i].wType:
                        read(mixin("this."~fields[i].name), buf);
                        break;
                }
            }
        }
    }
}
