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

import tango.stdc.posix.arpa.inet;
import tango.util.cipher.Cipher;
import tango.util.MinMax;

import tango.io.Stdout;
private ulong bigEndian64(ulong value) {
    version (LittleEndian) {
        return ((cast(ulong)htonl(value)) << 32) | htonl(value >> 32);
    }
    version (BigEndian) { return value; }
}

unittest {
    version (LittleEndian) {
        assert(bigEndian64(0x0011223344556677UL)
                        == 0x7766554433221100UL);
    }
    version (BigEndian) {
        assert(bigEndian64(0x0011223344556677UL)
                        == 0x0011223344556677UL);
    }
}

/****************************************************************************************
 * Implements the CTR/Counter Mode of Operation to convert a BlockCipher into a valid
 * StreamCipher.
 * The Counter itself is constructed by 64 leading bits unchanged by the counter, and 64
 * trailing bits incremented by the counter, and when needed wrapped.
 * See also: http://csrc.nist.gov/publications/nistpubs/800-38a/sp800-38a.pdf
 ***************************************************************************************/
class CounterCipher(BlockCipherIMPL) : Cipher {
private:
    BlockCipherIMPL _cipher;
    ubyte[] _nonce;

    ubyte[] _counterBlock;
    ulong* _counter;

    ubyte[] _keyStreamBlock;
    ulong[] _u64keyStreamBlock;
    int _used;

public:
    /************************************************************************************
     * Create a CounterCipher from a given BlockCipher, and IV/Nonce
     * Note: The underlying cipher is expected to have a blockSize evenly divisible by
             8, for performance optimization.
     ***********************************************************************************/
    this(ubyte[] key, ubyte[] nonce) {
        _cipher = new BlockCipherIMPL(true, key);
        assert(!(_cipher.blockSize % 8), "Cipher with a blocksize evenly divisible by eight is assumed.");
        if (nonce.length != _cipher.blockSize)
            invalid("Nonce needs to be the blockSize of the used cipher");

        _nonce = nonce.dup;
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
        _used = _keyStreamBlock.length;

        _counterBlock = _nonce.dup;
        _counter = cast(ulong*)_counterBlock+1;
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
    void nextKeyBlock() {
        _cipher.update(_counterBlock, _keyStreamBlock);
        _used = 0;
        *_counter = bigEndian64(bigEndian64(*_counter)+1);
    }
}


debug (UnitTest) {
    // Test-vectors from http://csrc.nist.gov/publications/nistpubs/800-38a/sp800-38a.pdf
    import tango.util.cipher.AES;
    unittest {
        auto key = x"2b7e151628aed2a6abf7158809cf4f3c";
        auto nonce = x"f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff";

        auto encrypter = new CounterCipher!(AES)(cast(ubyte[])key, cast(ubyte[])nonce);
        auto decrypter = new CounterCipher!(AES)(cast(ubyte[])key, cast(ubyte[])nonce);

        void test(char[] input, char[] cipherText) {
            char[16] store1, store2;
            encrypter.update(input, store1);
            assert(store1 == cipherText);
            decrypter.update(store1, store2);
            assert(store2 == input);
        }
        test(x"6bc1bee22e409f96e93d7e117393172a", x"874d6191b620e3261bef6864990db6ce");
        test(x"ae2d8a571e03ac9c9eb76fac45af8e51", x"9806f66b7970fdff8617187bb9fffdff");
        test(x"30c81c46a35ce411e5fbc1191a0a52ef", x"5ae4df3edbd5d35e5b4f09020db03eab");
        test(x"f69f2445df4f9b17ad2b417be66c3710", x"1e031dda2fbe03d1792170a0f3009cee");
    }
}
