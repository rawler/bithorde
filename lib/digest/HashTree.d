/*******************************************************************************

        copyright:      Copyright (c) 2010 Ulrik Mikaelsson. All rights reserved

        license:        TODO: decide

        version:        Initial release: Mar 2010

        author:         Ulrik Mikaelsson

        This module implements the HashTree algorithm by Ralph Merkle

*******************************************************************************/
module lib.digest.HashTree;

private import tango.util.container.more.Stack;
private import tango.util.digest.Digest;

/*******************************************************************************
 * Implementation of the Merkle Hash Tree.
 *
 * References: http://en.wikipedia.org/wiki/Hash_tree
*******************************************************************************/
class HashTree(DIGEST) : Digest {
private:
    DIGEST hasher;
    ubyte[][128] hashes; // 128-level tree, with the default 1k blocksize is a VERY large file of trillions of exabytes, yet consumes only 3.5k of memory to hash (with tiger)
    uint segmentsize;
    ubyte root_idx;
    size_t buffered;
    Stack!(ubyte[],hashes.length) _freeList;
public:
    this (size_t segmentsize=1024)
    {
        this.segmentsize = segmentsize;
        hasher = new DIGEST;
        for (int i; i < hashes.length; i++)
            _freeList.push(new ubyte[digestSize]);
        reset();
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
            if (buf) {
                _freeList.push(buf);
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
        auto buf = _freeList.pop();
        auto hash = hasher.binaryDigest(buf);
        int i;
        for (; hashes[i]; i++) {
            hasher.update(x"01");
            hasher.update(hashes[i]);
            hasher.update(hash);
            hash = hasher.binaryDigest(buf);

            _freeList.push(hashes[i]);
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
                data = data[munch..length];
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
        After completion, reset() the digest state
    ***********************************************************************/
    ubyte[] binaryDigest(ubyte[] buffer_ = null) {
        if (buffered || (!hashes[0] && !root_idx))
            mergeUp();

        if ((!buffer_) || (buffer_.length < digestSize))
            buffer_ = new ubyte[digestSize];
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
                    buffer_[] = hashes[i];
                }
            }
        }
        reset();
        return buffer_;
    }

    debug (UnitTest)
    {
        // Needs a Hash implementation to test with.
        import tango.util.digest.Tiger;
        unittest
        {
            static char[][] test_inputs = [
                "",
                x"00",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            ];

            static char[][] test_results = [
                "5d9ed00a030e638bdb753a6a24fb900e5a63b8e73e6c25b6",
                "aabbcca084acecd0511d1f6232a17bfaefa441b2982e5548",
                "5fbd0e62ad016d596b77d1d28883b94fed78ecbaf4640914",
                "7e591c1cd8f2e6121fdbcd8071ba279626b771642d10a3db",
            ];

            auto h = new HashTree!(Tiger);
            foreach (uint i, char[] input; test_inputs)
            {
                h.update(input);
                char[] digest = h.hexDigest();
                assert(digest == test_results[i],
                        "("~digest~") != ("~test_results[i]~")");
            }
        }
    }
}
