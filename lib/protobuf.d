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

import tango.core.Exception;
import tango.core.Traits;
import tango.util.MinMax;

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
    bool decode(ubyte[] buf);
}

class DecodeException : Exception { this(char[] msg) { super(msg); } }

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

bool decode_val(T : ubyte[])(ref ubyte[] buf, out T result) {
    uint vlen;
    if (decode_val!(uint)(buf, vlen) && (buf.length >= vlen)) {
        result = cast(T)buf[0 .. vlen];
        buf = buf[vlen .. length];
        return true;
    } else {
        return false;
    }
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

bool decode_val(T : long)(ref ubyte[] buf, out T result) {
    T retval = cast(T)0;
    uint idx = 0;
    foreach (b; buf) {
        retval ^= cast(T)(b & 0b01111111) << (idx++*7);
        if (!(b & 0b10000000))
        {
            buf = buf[idx .. length];
            result = retval;
            return true;
        }
    }
    return false;
}

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

    bool read(T:int)(out T member, ref ubyte[] buf) {
        return decode_val!(T)(buf, member);
    }
    bool read(T:ubyte[])(ref T member, ref ubyte[] buf) {
        return decode_val!(T)(buf, member);
    }
    bool read(T:ProtoBufMessage)(ref T member, ref ubyte[] buf) {
        size_t msglen;
        if (decode_val!(size_t)(buf, msglen) && (buf.length >= msglen)) {
            member.decode(buf[0..msglen]);
            buf = buf[msglen..length];
            return true;
        } else {
            return false;
        }
    }
    bool read(T:ProtoBufMessage)(ref T[] members, T allocated, ref ubyte[] buf) {
        uint msglen;
        if (decode_val!(size_t)(buf, msglen) && (buf.length >= msglen)) {
            allocated.decode(buf[0..msglen]);
            members ~= allocated;
            buf = buf[msglen..length];
            return true;
        } else {
            return false;
        }
    }

    bool consume_wtype(ubyte wtype, ref ubyte[] buf) {
        alias tango.util.MinMax.min!(int) int_min;
        switch (wtype) {
            case WireType.varint:
                uint _int;
                return decode_val!(uint)(buf, _int);
            case WireType.fixed64:
                if (buf.length >= 8) {
                    buf = buf[8..length];
                    return true;
                } else {
                    return false;
                }
            case WireType.length_delim:
                ubyte[] _buf;
                return decode_val!(ubyte[])(buf, _buf);
            case WireType.fixed32:
                if (buf.length >= 8) {
                    buf = buf[4..length];
                    return true;
                } else {
                    return false;
                }
            default:
                throw new DecodeException("Unknown WireType in message");
        }
    }
}

template _WTypeForDType(type) {
    const _WTypeForDType =  is(type: int) ? WireType.varint : WireType.length_delim;
}

struct PBMapping {
    char[] name;
    uint id;
};

template PBField(T, char[] name) {
    const PBField = T.stringof ~ " _pb_" ~ name ~ ";\n"
        ~ "bool "~name~"IsSet;\n"
        ~ T.stringof~" "~name~"() { return this._pb_"~name~"; }\n"
        ~ T.stringof~" "~name~"("~T.stringof~" val) { "~name~"IsSet=true; return this._pb_"~name~"=val; }\n";
}

template ProtoBufCodec(fields...) {
    final ubyte[] encode(ByteBuffer buf = new ByteBuffer) {
        foreach_reverse (int i, f; fields) {
            const code = (fields[i].id << 3) | _WTypeForDType!(typeof(mixin("this._pb_"~fields[i].name)));
            if (mixin("this."~fields[i].name~"IsSet"))
                write(code, mixin("this._pb_"~fields[i].name), buf);
        }
        return buf.data;
    }

    debug import tango.util.log.Log;
    final bool decode(ubyte[] buf) {
        while (buf.length > 0) {
            uint descriptor;
            if (decode_val!(uint)(buf, descriptor)) {
                try switch (descriptor>>3) {
                    foreach (int i, f; fields) {
                        case fields[i].id:
                            debug {
                                if ((descriptor & 0b0111) != _WTypeForDType!(typeof(mixin("this._pb_"~fields[i].name))))
                                    Log.lookup("bithorde").warn("Field with wrong WType parsed");
                            }
                            auto field = mixin("this._pb_"~fields[i].name); // Note, read-only. Since mixin will evalutate to variable declaration, cannot be written to
                            static if (is(typeof(field) : ProtoBufMessage))
                                field = new typeof(field);
                            static if (is(typeof(field[0]) : ProtoBufMessage))
                                read(mixin("this._pb_"~fields[i].name), new typeof(field[0]), buf);
                            else
                                read(mixin("this._pb_"~fields[i].name), buf);
                            mixin("this."~fields[i].name~"IsSet=true;");
                            break;
                    }
                } catch (tango.core.Exception.SwitchException e) {
                    consume_wtype(descriptor & 0b00000111, buf);
                }
            } else {
                return false;
            }
        }
        return true;
    }
}