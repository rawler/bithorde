module lib.digest.ED2K;

private import tango.util.digest.Digest;
private import tango.util.digest.Md4;

/**
 * Implementation of the Edonkey2000 Hash List Algorithm
 *
 * References: http://www.open-content.net/specs/draft-jchapweske-thex-02.html
 */
class ED2K : Digest {
private:
    const segmentSize = 9728000;

    Md4 part_hasher, root_hasher;
    uint segments, buffered;
public:
    this () {
        part_hasher = new Md4;
        root_hasher = new Md4;
        reset();
    }

    uint digestSize()
    {
        return root_hasher.digestSize;
    }

    void reset()
    {
        buffered = segments = 0;
        part_hasher.reset();
        root_hasher.reset();
    }

    ED2K update(void[] data) {
        uint munch = segmentSize - buffered;
        if (munch > data.length) { // If not enough to fill block, just buffer
            part_hasher.update(data);
            buffered += data.length;
        } else { // Process as many full blocks as possible
            ubyte[16] tmpDigest; // Md4 digest is 16 bytes. Use for storing part_result
            while (data.length >= munch) {
                part_hasher.update(data[0..munch]);
                root_hasher.update(part_hasher.binaryDigest(tmpDigest));
                segments += 1;
                data = data[munch..length];
                munch = segmentSize;
            }
            buffered = data.length;
            if (buffered > 0)
                part_hasher.update(data);
        }
        return this;
    }

    ubyte[] binaryDigest(ubyte[] buffer_ = null) {
        // Ensure we got a buffer large enough
        if ((!buffer_) || (buffer_.length < digestSize))
            buffer_ = new ubyte[digestSize];

        auto retval = part_hasher.binaryDigest(buffer_);
        assert(retval.ptr is buffer_.ptr);

        if (segments > 0) { // More than one segment
            root_hasher.update(retval);
            retval = root_hasher.binaryDigest(buffer_);
            assert(retval.ptr is buffer_.ptr);
        }
        reset();
        return retval;
    }

    debug (UnitTest)
    {
        unittest
        {
            static zeroblock = x"00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
            char[][uint] tests = [
                0     : "31d6cfe0d16ae931b73c59d7e0c089c0",
                1     : "6d134ac6b1205dae582e16234894fb90",
                9499  : "ee822ab4a90f909848f9385f06868a8a",
                9500  : "fc21d9af828f92a8df64beac3357425d",
                9501  : "12df1ad050dee78471f6e13d53eec88d",
                18999 : "81a1b7a308a576694b89383b22edc9c1",
                19000 : "114b21c63a74b6ca922291a11177dd5c",
                19001 : "3f16900dded63a273bc6d4c1f8a1c312",
            ];
            auto h = new ED2K;
            foreach (uint input, char[] result; tests)
            {
                for (uint i=0; i < input; i++)
                    h.update(zeroblock);
                char[] digest = h.hexDigest();
                assert(digest == result,
                        "("~digest~") != ("~result~")");
            }
        }
    }
}
