module lib.cipher.counter;

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

import tango.util.cipher.Cipher;
import tango.util.MinMax;

/****************************************************************************************
 * Implements the CTR/Counter Mode of Operation to convert a BlockCipher into a valid
 * StreamCipher.
 ***************************************************************************************/
class CounterCipher(BlockCipherIMPL) : Cipher {
private:
    BlockCipherIMPL _cipher;
    ubyte[] _nonce;

    ubyte[] _keyStreamBlock;
    ubyte[] _tmpBuf;
    int _used;
    ulong _counter;

    ulong[] _u64nonce, _u64tmpBuf, _u64keyStreamBlock;
public:
    /************************************************************************************
     * Create a CounterCipher from a given BlockCipher, and IV/Nonce
     * Note: The underlying cipher is expected to have a blockSize evenly divisible by
             8, for performance optimization.
     ***********************************************************************************/
    this(ubyte[] key, ubyte[] nonce) {
        _cipher = new BlockCipherIMPL(true, key);
        assert(!(_cipher.blockSize % 8), "Cipher with a blocksize evenly divisible by eight is assumed2.");
        if (nonce.length != _cipher.blockSize)
            invalid("Nonce needs to be the blockSize of the used cipher");

        _nonce = cast(ubyte[])nonce.dup;
        _u64nonce = cast(ulong[])_nonce;
        reset();
    }

    /************************************************************************************
     * Implement Cipher.name
     ***********************************************************************************/
    char[] name() { return "CTR_" ~ _cipher.name; }

    /************************************************************************************
     * Implement Cipher.reset
     ***********************************************************************************/
    void reset() {
        _initialized = true;
        _cipher.reset();
        _keyStreamBlock = new ubyte[_nonce.length];
        _u64keyStreamBlock = cast(ulong[])_keyStreamBlock;
        _tmpBuf = _nonce.dup;
        _u64tmpBuf = cast(ulong[])_tmpBuf;
        _used = _keyStreamBlock.length;
        _counter = 0;
    }

    /************************************************************************************
     * Implement Cipher.update
     * @note: The point of CounterCipher is to make a block-cipher into a stream-chiper,
     *        so input_.length can be of any size.
     ***********************************************************************************/
    uint update(void[] input_, void[] output_) in {
        assert(output_.length >= input_.length);
    } body {
        auto input = cast(ubyte[])(input_);
        auto output = cast(ubyte[])(output_);
        do {
            if (_used == _keyStreamBlock.length)
                nextKeyBlock;
            size_t blkLen;

            if ((!_used) && (input.length >= _keyStreamBlock.length)) {
                blkLen = _keyStreamBlock.length;
                auto u64out = cast(ulong*)output.ptr;
                auto u64in = cast(ulong*)input.ptr;
                foreach (i, u64key; _u64keyStreamBlock)
                    u64out[i] = u64in[i] ^ u64key;
            } else {
                auto keyBlock = _keyStreamBlock[_used..$];
                blkLen = min(input.length, keyBlock.length);
                foreach (i, c; input[0..blkLen])
                    output[i] = c ^ keyBlock[i];
            }

            input = input[blkLen..$];
            output = output[blkLen..$];
            _used += blkLen;
        } while (input.length);

        return input_.length;
    }

private:
    void writeInLittleEndian(ulong val, ubyte[] buf) {
        version (LittleEndian) {
            auto ptr = cast(ulong*)(buf.ptr);
            *ptr = val;
        } else {
            static assert (false, "Needs implementation");
        }
    }

    void nextKeyBlock() {
        _tmpBuf[0..$] = 0;
        writeInLittleEndian(_counter++, _tmpBuf);
        foreach (i, ref u64; _u64tmpBuf) {
            u64 ^= _u64nonce[i];
        }
        _cipher.update(_tmpBuf, _keyStreamBlock);
        _used = 0;
    }
}


debug (UnitTest) {
    import tango.util.cipher.AES;
    import tango.io.Stdout;
    unittest {
        void testRoundtrip(char[] key, char[] nonce, char[] clearText, ubyte[] expectedCipher) {
            auto encrypter = new CounterCipher!(AES)(cast(ubyte[])key, cast(ubyte[])nonce);

            auto cipherText = new ubyte[clearText.length];
            encrypter.update(clearText, cipherText);
            assert(expectedCipher == cipherText);

            auto decrypter = new CounterCipher!(AES)(cast(ubyte[])key, cast(ubyte[])nonce);

            auto clearText2 = new char[clearText.length];
            decrypter.update(cipherText, clearText2);

            assert(clearText == clearText2);
        }

        testRoundtrip("Some 16-bit Key.", "Some 16-bit Nonc", "", []);
        testRoundtrip("Some 16-bit Key.", "Some 16-bit Nonc", "T", [81]);
        testRoundtrip("Some 16-bit Key.", "Some 16-bit Key.", "The", [123, 63, 85]);
        testRoundtrip("Some 16-bit Key.", "Some 16-bit Key.", "The quick brown fox jumps over the lazy dog", [123, 63, 85, 162, 134, 27, 194, 32, 202, 27, 131, 241, 233, 196, 129, 129, 100, 39, 159, 69, 144, 209, 163, 29, 140, 172, 72, 32, 169, 85, 20, 142, 84, 164, 38, 8, 135, 242, 116, 186, 86, 30, 96]);
    }
}
