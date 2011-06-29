module lib.cipher.hmac;

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

import tango.util.digest.Digest;

import tango.util.digest.Md5 : Md5;
import tango.util.digest.Sha1 : Sha1;
import tango.util.digest.Sha256 : Sha256;
import tango.util.digest.Sha512 : Sha512;

/****************************************************************************************
 * Compute HMAC for a given key and message, as outlined in RFC2104.
 * @see: http://tools.ietf.org/html/rfc2104
 ***************************************************************************************/
ubyte[] HMAC(DigestImpl)(ubyte[] key, void[] msg, DigestImpl digest=null, ubyte[] output=null) {
    // TODO: Should somehow be figured by digest.blockSize, but that is not accessible
    // For now, hardcode to the supported Digests.
    static if (is(DigestImpl : Md5)
               || is(DigestImpl : Sha1)
               || is(DigestImpl : Sha256))
        auto B = 64;
    else static if (is(DigestImpl: Sha512))
        auto B = 128;
    else
        static assert(false, T.stringof ~ " is not a supported HMAC-digest");

    if (digest is null)
        digest = new DigestImpl;

    if (output == null)
        output = new ubyte[digest.digestSize];
    assert(output.length >= digest.digestSize);

    if (key.length > B) {
        digest.update(key);
        key = digest.binaryDigest();
    }

    // First, calculate k_ipad
    scope key_pad = new ubyte[B];
    key_pad[0..key.length] = key;
    key_pad[key.length..$] = 0x00;
    foreach (ref b; cast(ulong[])key_pad)
        b ^= 0x3636363636363636;

    // Compute digest of right part of end-expression
    digest.update(key_pad);
    digest.update(msg);
    scope rightPart = digest.binaryDigest(output);

    // Re-use key_pad buffer to calculate k_opad
    foreach (ref b; cast(ulong[])key_pad)
        b ^= 0x3636363636363636 ^ 0x5c5c5c5c5c5c5c5c; // XOR is commutative, so figure out key by XOR:ing away the old padding.

    // Compute final digest
    digest.update(key_pad);
    digest.update(rightPart);
    return digest.binaryDigest(output);
}

debug (UnitTest) {
    import tango.io.Stdout;
    char[] test(DigestImpl)(char[] key, char[] msg) {
        return cast(char[])HMAC!(DigestImpl)(cast(ubyte[])key, msg);
    }
    unittest {
        assert(test!(Md5)("", "") == x"74e6f7298a9c2d168935f58c001bad88");
        assert(test!(Sha1)("", "") == x"fbdb1d1b18aa6c08324b7d64b71fb76370690e1d");
        assert(test!(Sha256)("", "") == x"b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad");
        assert(test!(Sha512)("", "") == x"b936cee86c9f87aa5d3c6f2e84cb5a4239a5fe50480a6ec66b70ab5b1f4ac6730c6c515421b327ec1d69402e53dfb49ad7381eb067b338fd7b0cb22247225d47");

        assert(test!(Md5)("key", "The quick brown fox jumps over the lazy dog") == x"80070713463e7749b90c2dc24911e275");
        assert(test!(Sha1)("key", "The quick brown fox jumps over the lazy dog") == x"de7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9");
        assert(test!(Sha256)("key", "The quick brown fox jumps over the lazy dog") == x"f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8");
        assert(test!(Sha512)("key", "The quick brown fox jumps over the lazy dog") == x"b42af09057bac1e2d41708e48a902e09b5ff7f12ab428a4fe86653c73dd248fb82f948a549f7b791a5b41915ee4d1ec3935357e4e2317250d0372afa2ebeeb3a");
    }
}