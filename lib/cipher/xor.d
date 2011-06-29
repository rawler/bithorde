module lib.cipher.xor;

/*****************************************************************************************
 *   Copyright: Copyright (C) 2011 Ulrik Mikaelsson. All rights reserved
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

import tango.core.Exception;
import tango.util.cipher.Cipher;
import tango.util.Convert;
import tango.util.MinMax;

/****************************************************************************************
 * High-performance obfuscation.
 *
 * WARNING: XORCipher is NOT a real Cipher. It is NOT secure, at all. Do NOT use for
 *          anything needing real security. XORCipher makes it just a _tiny_ bit more
 *          difficult to sniff traffic, at a very low CPU cost.
 *
 *          You have been warned.
 ***************************************************************************************/
class XORCipher : Cipher {
private:
  ubyte[32] _keyBuf;
  ulong[_keyBuf.sizeof/ulong.sizeof] _key64;
  size_t _used;
public:
    this(ubyte[] key) {
        if (key.length < _keyBuf.sizeof)
            throw new AssertException("Needs at least "~to!(char[])(_keyBuf.sizeof*8)~" bits of key.", __FILE__, __LINE__);
        _keyBuf[] = key;
        _key64[] = cast(ulong[])_keyBuf;
    }

    size_t update(void[] input_, void[] output_) {
        // TODO: Merge with Counter. No sense in having dual block-XOR-implementations.
        auto input = cast(ubyte[])input_;
        auto output = cast(ubyte[])output_;
        auto inlen = input.length;
        while (input.length) {
            size_t blkLen;
            if ((_used == 0) && (input.length >= _keyBuf.length)) {
                blkLen = _keyBuf.length;
                auto in64 = cast(ulong*)input;
                auto out64 = cast(ulong*)output;
                foreach (i,k; _key64)
                    out64[i] = in64[i] ^ k;
            } else {
                auto keyBlock = _keyBuf[_used..$];
                blkLen = min(input.length, keyBlock.length);
                foreach (i, k; keyBlock[0..blkLen])
                    output[i] = input[i] ^ k;
                _used = (_used + blkLen) % _keyBuf.length;
            }
            input = input[blkLen..$];
            output = output[blkLen..$];
        }
        return inlen;
    }

    char[] name() { return "XORCipher"; }
    void reset() { _used = 0; }
}
