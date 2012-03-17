/****************************************************************************************
 * This module implements the HashTree algorithm by Ralph Merkle
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
 ******************************************************************************/
module lib.digest.HashTree;

private import tango.core.Exception;
private import tango.io.device.Array;
private import tango.io.stream.Data;
private import tango.util.container.more.Stack;
private import tango.util.digest.Digest;

private import lib.digest.stateful;
private import ne = lib.networkendian;

/*******************************************************************************
 * Implementation of the Merkle Hash Tree.
 *
 * References: http://en.wikipedia.org/wiki/Hash_tree
*******************************************************************************/
class HashTree(DIGEST:IStatefulDigest) : Digest, IStatefulDigest {
private:
    DIGEST hasher;
    ubyte[][128] hashes; // 128-level tree, with the default 1k blocksize is a VERY large file of trillions of exabytes, yet consumes only 3.5k of memory to hash (with tiger)
    uint segmentsize;
    ubyte root_idx;
    size_t buffered;
    Stack!(ubyte[], hashes.length) _freeList;
public:
    this (size_t segmentsize=1024)
    {
        this.segmentsize = segmentsize;
        hasher = new DIGEST;
        for (int i; i < hashes.length; i++)
            _freeList.push(new ubyte[digestSize]);
        reset();
    }

    private ubyte[] allocDigestBuf() {
        if (_freeList.size)
            return _freeList.pop;
        else
            return new ubyte[digestSize];
    }

    private void freeDigestBuf(ubyte[] buf) {
        if (_freeList.unused)
            _freeList.push(buf);
        else
            delete buf;
    }

    /***********************************************************************
            Satisfy IStatefulDigest
    ***********************************************************************/
    char[] hexDigest(char[] buffer = null) {
        return super.hexDigest(buffer);
    }

    /***********************************************************************
        Store state to provided buffer
    ***********************************************************************/
    ubyte[] save(ubyte[] buf) {
        auto wbuf = buf[hasher.save(buf).length..$];
        auto arr = new Array(wbuf, 0);
        auto outp = new DataOutput(arr);
        outp.endian(DataOutput.Network);
        outp.int8(root_idx);
        foreach (h; hashes[0..root_idx+1]) {
            outp.int8(h.length);
            if (h.length) {
                auto w = outp.write(h);
                assert(w == h.length);
            }
        }
        outp.int32(segmentsize);
        outp.int32(buffered);
        return buf[0..(wbuf.ptr-buf.ptr)+arr.limit];
    }

    /***********************************************************************
        Load state from provided buffer
    ***********************************************************************/
    size_t load(ubyte[] buf) {
        auto rbuf = buf[hasher.load(buf)..$];
        auto arr = new Array(rbuf);
        auto inp = new DataInput(arr);
        inp.endian(DataInput.Network);
        root_idx = inp.int8;
        foreach (ref h; hashes[0..root_idx+1]) {
            ubyte blen = inp.int8;
            if (blen) {
                assert(blen == digestSize);
                h = allocDigestBuf;
                auto r = inp.read(h);
                if (r != blen)
                    throw new IOException("Failed to load expected hashing-state.");
            }
        }
        segmentsize = inp.int32;
        buffered = inp.int32;
        return (rbuf.ptr - buf.ptr) + arr.position;
    }

    /***********************************************************************
        Maximum size of state. Depends on underlying hash.
    ***********************************************************************/
    size_t maxStateSize() {
        return segmentsize.sizeof + root_idx.sizeof +
               buffered.sizeof + (hashes.length*(1+hasher.digestSize)) +
               hasher.maxStateSize;
    }

    /***********************************************************************
        The size of a HashTree digest is determined by the underlying
        HashTree implementation
    ***********************************************************************/
    uint digestSize()
    {
        return hasher.digestSize;
    }

    /***********************************************************************
        Reset the digest

        Remarks:
        Returns the digest state to it's initial value
    ***********************************************************************/
    void reset()
    {
        foreach (ref buf; hashes) {
            if (buf.length) {
                freeDigestBuf(buf);
                buf = null;
            }
        }
        buffered = 0;
        root_idx = 0;
        hasher.reset();
        hasher.update(x"00");
    }

    /***********************************************************************
        Process a finished segment, and push node to tree
    ***********************************************************************/
    private void mergeUp() {
        auto buf = allocDigestBuf;
        auto hash = hasher.binaryDigest(buf);
        int i;
        for (; hashes[i].length; i++) {
            hasher.update(x"01");
            hasher.update(hashes[i]);
            hasher.update(hash);
            hash = hasher.binaryDigest(buf);

            freeDigestBuf(hashes[i]);
            hashes[i] = null;
        }
        hashes[i] = hash;
        if (i > root_idx)
            root_idx = i;
        hasher.update(x"00");
    }

    /***********************************************************************
        Update the digest with more data
    ***********************************************************************/
    HashTree!(DIGEST) update(void[] data) {
        uint munch = segmentsize - buffered;
        if (munch > data.length) { // If not enough to fill block, just buffer
            hasher.update(data);
            buffered += data.length;
        } else { // Process as many full blocks as possible
            while (data.length >= munch) {
                hasher.update(data[0..munch]);
                mergeUp();
                data = data[munch..$];
                munch = segmentsize;
            }
            buffered = data.length;
            if (buffered > 0)
                hasher.update(data);
        }
        return this;
    }

    /***********************************************************************
        Get the final digest-result

        Remarks:
        After completion, reset()s the digest state
    ***********************************************************************/
    ubyte[] binaryDigest(ubyte[] buffer_ = null) {
        if (buffered || (!hashes[0] && !root_idx))
            mergeUp();

        if ((!buffer_) || (buffer_.length < digestSize))
            buffer_ = allocDigestBuf;
        ubyte[] ret = null;
        hasher.reset();
        // Merge everything up to root
        for (uint i; i <= root_idx; i++) {
            if (hashes[i]) {
                if (ret) {
                    hasher.update(x"01");
                    hasher.update(hashes[i]);
                    hasher.update(ret);
                    ret = hasher.binaryDigest(buffer_);
                    assert(ret.ptr == buffer_.ptr);
                } else {
                    ret = buffer_[] = hashes[i];
                }
            }
        }
        reset();
        return ret;
    }

    debug (UnitTest)
    {
        // Needs a Hash implementation to test with.
        import lib.digest.Tiger;
        import tango.core.tools.TraceExceptions;
        static import base32 = lib.base32;

        unittest // From http://web.archive.org/web/20080316033726/http://www.open-content.net/specs/draft-jchapweske-thex-02.html
        {
            static char[][] test_inputs = [
                "",
                x"00",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            ];

            static char[][] test_results = [
                "LWPNACQDBZRYXW3VHJVCJ64QBZNGHOHHHZWCLNQ",
                "VK54ZIEEVTWNAUI5D5RDFIL37LX2IQNSTAXFKSA",
                "L66Q4YVNAFWVS23X2HJIRA5ZJ7WXR3F26RSASFA",
                "PZMRYHGY6LTBEH63ZWAHDORHSYTLO4LEFUIKHWY",
            ];

            auto h = new HashTree!(Tiger);
            foreach (uint i, char[] input; test_inputs)
            {
                h.update(input);
                char[] digest = base32.encode(h.binaryDigest, false);
                assert(digest == test_results[i],
                        "("~digest~") != ("~test_results[i]~")");
            }
        }

        unittest // Verify X*11*"A" for various X
        {
            static uint[] test_iters = [
                10,
                11,
                21,
                22,
                337,
            ];

            static char[][] test_results = [
                "VYX67IZT5P7ZDZXZAIMZEQJTUGR4X547Z3BGEAY",
                "IWJQ24BQ4WZI2DSJOY2UXTUREPMEVPBP32LKGNA",
                "VBQ7BISX6FA4VHW6VFYLDIL45UAKVLPFZN5UILA",
                "5E6JJPXXFIL6Q6WEYO7MWIUU6I4QWD7PS5SWGIY",
                "LTCFSQXC3WVNIGVNLWHJKHXADRUN2Q24XL5P3OY",
            ];

            auto h = new HashTree!(Tiger);
            foreach (uint i, uint x; test_iters)
            {
                for (; x > 0; x--)
                    h.update("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
                char[] digest = base32.encode(h.binaryDigest, false);
                assert(digest == test_results[i],
                        "("~digest~") != ("~test_results[i]~")");
            }
        }

        unittest // Verify save/load works as intended
        {
            auto test = x"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
            auto testcnt = 1024;
            auto reference = new HashTree!(Tiger);
            for (auto i=0; i < testcnt; i++)
                reference.update(test);
            auto result = reference.hexDigest;

            ubyte[] buf = new ubyte[reference.maxStateSize];

            for (auto split = 0; split <= testcnt; split+=16) {
                scope a = new HashTree!(Tiger);
                for (auto i=0; i < split; i++)
                    a.update(test);
                scope state1 = a.save(buf).dup;

                for (auto i=split; i < testcnt; i++)
                    a.update(test);
                assert(a.hexDigest() == result);

                scope b = new HashTree!(Tiger);
                b.load(state1);
                scope state2 = b.save(buf).dup;
                assert(state1 == state2);

                for (auto i=split; i < testcnt; i++)
                    b.update(test);

                assert(b.hexDigest() == result);
            }
        }
    }
}
