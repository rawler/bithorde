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

module lib.networkendian;

import tango.core.ByteSwap;
import tango.core.BitManip;

/// Struct with static functions to convert to/from native byte-order and (BigEndian)network-byteorder

version (BigEndian) {
    void bswapa16(void[] dst) {}
    void bswapa32(void[] dst) {}
    void bswapa64(void[] dst) {}
    void bswapa80(void[] dst) {}

    ushort bswap16(ushort v) {}
    uint bswap32(uint v) {}
    ulong bswap64(ulong v) {}
} else version (LittleEndian) {
    alias ByteSwap.swap16 bswapa16;
    alias ByteSwap.swap32 bswapa32;
    alias ByteSwap.swap64 bswapa64;
    alias ByteSwap.swap80 bswapa80;

    ushort bswap16(ushort v) {
        return (v<<8) | (v>>8);
    }

    alias bswap bswap32;

    ulong bswap64(ulong v) {
        ulong a = cast(ulong)bswap(v)<<32;
        ulong b = bswap(v>>32);
        return a | b;
    }
} else {
    static assert(false, "Needs byteswap-implemenatation for mixed-endian system");
}

version (LittleEndian) unittest {
    assert(bswap16(0x1122) == 0x2211);
    assert(bswap32(0x11223344) == 0x44332211);
    assert(bswap64(0x1122334455667788L) == 0x8877665544332211L);
}
