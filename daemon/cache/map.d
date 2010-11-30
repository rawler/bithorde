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

module daemon.cache.map;

private import tango.io.device.Array;
private import tango.io.model.IConduit;
private import tango.io.stream.Data;

private import lib.message;
private import lib.networkendian;

/****************************************************************************************
 * CacheMap is the core datastructure for tracking which segments of an asset is
 * currently in cache or not.
 *
 * Authors: Ulrik Mikaelsson
 * Note: Doesn't deal with 0-length files
 ***************************************************************************************/
final class CacheMap {
    class LoadException : Exception {
        this(char[] msg = "Failed loading map") { super(msg); }
    }

    struct Header {
        ubyte ver = 2;            /// Version of the current map
        ulong hashedAmount;      /// Amount of bytes hashed starting from pos0
        ubyte[][HashType] hashes; /// Hash-states from pos0->hashedAmount
    }

    /************************************************************************************
     * Structure for defining the individual segments of the file
     ***********************************************************************************/
    struct Segment {
        ulong start;
        ulong end;

        bool isEmpty() { return !end; }
        ulong length() { return end-start; }

        /********************************************************************************
         * Merge other Segment into this (think of it as range-union)
         *******************************************************************************/
        Segment* opOrAssign(Segment other) {
            if (other.start < this.start)
                this.start = other.start;
            if (this.end < other.end)
                this.end = other.end;
            return this;
        }

        /********************************************************************************
         * Return new segment expanded by a certain amount.
         *
         * Segments expanded both up and down, so the length of the new segment will be
         * increased by 2 * amount (but clipped to start=0)
         *******************************************************************************/
        Segment expanded(uint amount=1)
        out (result) {
            assert( (this.start == 0) || (result.length == this.length + 2*amount) );
        } body {
            return Segment((start>=amount)?start-amount:start, end+amount);
        }
    }

    Segment[] segments;
    Header header;
public:
    /************************************************************************************
     * Empty constructor
     ***********************************************************************************/
    this() {}

    /************************************************************************************
     * Create clone of other CacheMap
     ***********************************************************************************/
    this(CacheMap other) {
        this.segments = other.segments.dup;
    }

    /************************************************************************************
     * Count of cached segments of the asset
     ***********************************************************************************/
    final uint segcount() { return segments.length; }

    /************************************************************************************
     * Amount of cached content in the asset
     ***********************************************************************************/
    ulong assetSize() {
        ulong retval;
        foreach (s; segments[0..segcount])
            retval += s.length;
        return retval;
    }

    /************************************************************************************
     * squash useless 0-size segments. Artifact from beta1, won't be needed later.
     ***********************************************************************************/
    void store_hashes(ulong hashedAmount, ubyte[][HashType] hashes) {
        header.hashedAmount = hashedAmount;
        header.hashes = null;
        foreach (k,v; hashes) {
            header.hashes[k] = v.dup;
        }
    }

    /************************************************************************************
     * squash useless 0-size segments. Artifact from beta1, won't be needed later.
     ***********************************************************************************/
    private void squashEmpty() {
        auto len = segments.length;
        foreach (i, ref x; segments) {
            if (x.end == x.start) {
                len -= 1;
                for (auto j=i; j < len; j++)
                    segments[j] = segments[j+1];
            } else if (x.end < x.start) {
                throw new LoadException("Serious corruption, discarding");
            }
        }
        segments.length = len;
    }

    /************************************************************************************
     * Load from the legacy V1-format.
     ***********************************************************************************/
    private void load_v1(ubyte[] data) {
        header = header.init;
        segments = cast(Segment[])data.dup;
    }

    /************************************************************************************
     * Load from the current V2-format.
     ***********************************************************************************/
    private void load_v2(ubyte[] data) {
        // Setup input stream
        auto buf = new Array(data);
        auto stream = new DataInput(buf);
        stream.endian(stream.Network);

        // Read header
        header.ver = stream.getByte;
        header.hashedAmount = stream.getLong;

        // Read hashes
        header.hashes = null;
        auto hashCount = stream.getShort;
        for (auto i = hashCount; hashCount > 0; hashCount--) {
            HashType type = cast(HashType)stream.getByte;
            ubyte[] hash = cast(ubyte[])stream.array;
            header.hashes[type] = hash;
        }

        // Read segments
        auto segcount = stream.getInt;
        segments.length = segcount;
        for (auto i = 0; i<segcount; i++) {
            ulong start = stream.getLong;
            ulong end = stream.getLong;

            segments[i].start = start;
            segments[i].end = end;
        }
    }

    /************************************************************************************
     * Load from provided InputStream, auto-detecting format.
     ***********************************************************************************/
    CacheMap load(InputStream stream) {
        scope data = cast(ubyte[])stream.load;
        try {
            if ((data.length%8)==0)
                load_v1(data);
            else if (data[0] == 2)
                load_v2(data);
            else
                throw new LoadException("Unsupported Format");
            squashEmpty();
        } catch (Exception e) {
            segments.length = 0;
            header.ver = 1;
            header.hashedAmount = 0;
            header.hashes = null;
        }
        return this;
    }

    /************************************************************************************
     * Write V2-format to provided OutputStream
     ***********************************************************************************/
    void write(OutputStream stream) {
        // Setup input stream
        scope ds = new DataOutput(stream);
        ds.endian(ds.Network);

        // Write header
        ds.putByte(header.ver);
        ds.putLong(header.hashedAmount);

        // Write hashes
        ds.putShort(header.hashes.length);
        foreach (type, hash; header.hashes) {
            ds.putByte(type);
            ds.array(hash);
        }

        // Write segments
        ds.putInt(segments.length);
        foreach(seg; segments) {
            ds.putLong(seg.start);
            ds.putLong(seg.end);
        }
        ds.flush();
    }

    /************************************************************************************
     * Check if a segment is completely in the cache.
     ***********************************************************************************/
    bool has(ulong start, uint length) in {
        assert(length > 0, "CacheMap.has() is undefined for 0-length.");
    } body {
        auto end = start+length;
        uint i;
        for (; (i < segcount) && (segments[i].end < start); i++) {}
        if (i==segcount)
            return false;
        else
            return (start>=segments[i].start) && (end<=segments[i].end);
    }

    /************************************************************************************
     * Add a segment into the cachemap
     ***********************************************************************************/
    void add(ulong start, uint length) {
        // Just skip 0-length segments
        if (!length) return;

        // Original new segment
        auto news = Segment(start, start + length);

        // Expanded segment to cover neighbors.
        auto anew = news.expanded;

        uint i;
        // Find insertion-point
        for (; (i < segments.length) && (segments[i].end < anew.start); i++) {}
        assert(i <= segments.length);

        // Append, Update or Insert ?
        if (i == segments.length) {
            // Append
            segments ~= news;
        } else if (segments[i].start <= anew.end) {
            // Update
            segments[i] |= news;
        } else {
            // Insert, need to ensure we have space, and shift trailing segments up a position
            segments.length = segments.length + 1;
            for (auto j=segments.length-1;j>i;j--)
                segments[j] = segments[j-1];
            segments[i] = news;
        }

        // Squash possible trails (merge any intersecting or adjacent segments)
        uint j = i+1;
        for (;(j < segments.length) && (segments[j].start <= (segments[i].end+1)); j++)
            segments[i] |= segments[j];

        // Right-shift the rest
        uint shift = j-i-1;
        if (shift) {
            auto newlen = segments.length - shift; // New segments.length
            // Shift down valid segments
            for (i+=1; i < newlen; i++)
                segments[i] = segments[i+shift];
            segments.length = newlen;
        }
    }

    /************************************************************************************
     * Find the size of any block starting at offset 0
     *
     * Returns: The length of the block or 0, if no such block exists
     ***********************************************************************************/
    ulong zeroBlockSize() {
        if (segments[0].start == 0)
            return segments[0].end;
        else
            return 0;
    }

    unittest {
        auto map = new CacheMap();
        map.add(0,15);
        assert(map.segments[0].start == 0);
        assert(map.segments[0].end == 15);
        map.add(30,15);
        assert(map.segments[1].start == 30);
        assert(map.segments[1].end == 45);
        assert(map.segments.length == 2);
        map.add(45,5);
        assert(map.segments[1].start == 30);
        assert(map.segments[1].end == 50);
        assert(map.segments.length == 2);
        map.add(25,5);
        assert(map.segments[1].start == 25);
        assert(map.segments[1].end == 50);
        assert(map.segments.length == 2);

        map.add(18,2);
        assert(map.segments[0].start == 0);
        assert(map.segments[0].end == 15);
        assert(map.segments[1].start == 18);
        assert(map.segments[1].end == 20);
        assert(map.segments[2].start == 25);
        assert(map.segments[2].end == 50);

        map.add(11,7);
        assert(map.segments[0].start == 0);
        assert(map.segments[0].end == 20);
        assert(map.segments[1].start == 25);
        assert(map.segments[1].end == 50);
        assert(map.segments.length == 2);

        assert(map.has(0,10) == true);
        assert(map.has(1,15) == true);
        assert(map.has(16,15) == false);
        assert(map.has(29,5) == true);
        assert(map.has(30,5) == true);
        assert(map.has(35,5) == true);
        assert(map.has(45,5) == true);
        assert(map.has(46,5) == false);

        map = new CacheMap();
        map.add(0,0);
        assert(map.segments.length == 0);
        map.segments = [Segment(0,0)];
        map.add(0, 10);
        assert(map.segments.length == 1);
        assert(map.segments[0].start == 0);
        assert(map.segments[0].end == 10);
        map.add(10, 5);
        assert(map.segments.length == 1);
        map.add(20, 5);
        assert(map.segments.length == 2);
        map.add(16,3);
        assert(map.segments.length == 1);

        map = new CacheMap();
        map.add(10,5);
        map.add(0,5);
        assert(map.segments.length == 2);
        assert(map.segments[0].start == 0);
        assert(map.segments[0].end == 5);
        assert(map.segments[1].start == 10);
        assert(map.segments[1].end == 15);
        assert(map.has(4,1));
        assert(!map.has(5,1));
        assert(!map.has(8,2));
        assert(map.has(10,5));
        assert(!map.has(10,6));

        // Now test inserting many segments, to verify it expands correctly
        map.add(1000, 5);
        for (int i=0; i < 20; i++)
            map.add(10*i, 5);
    }
}

