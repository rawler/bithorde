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

private import tango.io.device.File;
private import tango.io.device.FileMap;
private import tango.io.FilePath;

/****************************************************************************************
 * CacheMap is the core datastructure for tracking which segments of an asset is
 * currently in cache or not.
 *
 * Authors: Ulrik Mikaelsson
 * Note: Doesn't deal with 0-length files
 ***************************************************************************************/
final class CacheMap {
private:
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
    uint _segcount;
    MappedFile file;
    void ensureIdxAvail(uint length) {
        if (length > segments.length)
            segments = cast(Segment[])file.resize(Segment.sizeof * length);
    }
public:
    FilePath path;

    /************************************************************************************
     * Initialize and open a CacheMap backed by a given File
     ***********************************************************************************/
    this(FilePath path) {
        this.path = path;
        file = new MappedFile(path.toString, File.ReadWriteOpen);
        if (file.length)
            segments = cast(Segment[])file.map();
        else
            segments = cast(Segment[])file.resize(Segment.sizeof * 16);
        for (; !segments[_segcount].isEmpty; _segcount++) {}
    }

    /***********************************************************************************
     * Count of cached segments of the asset
     **********************************************************************************/
    uint segcount() { return _segcount; }

    /***********************************************************************************
     * Amount of cached content in the asset
     **********************************************************************************/
    ulong assetSize() {
        ulong retval;
        foreach (s; segments[0..segcount])
            retval += s.length;
        return retval;
    }

    void close() {
        if (file) {
            file.close();
            file = null;
        }
    }

    /************************************************************************************
     * Check if a segment is completely in the cache.
     ***********************************************************************************/
    bool has(ulong start, uint length) {
        auto end = start+length;
        uint i;
        for (; (i < _segcount) && (segments[i].end < start); i++) {}
        if (i==_segcount)
            return false;
        else
            return (start>=segments[i].start) && (end<=segments[i].end);
    }

    /************************************************************************************
     * Add a segment into the cachemap
     ***********************************************************************************/
    void add(ulong start, uint length) {
        // Original new segment
        auto onew = Segment(start, start + length);

        // Expand start and end with 1, to cover adjacency
        auto anew = onew.expanded(1);

        uint i;
        // Find insertion-point
        for (; (i < _segcount) && (segments[i].end <= anew.start); i++) {}
        assert(i <= _segcount);

        // Append, Update or Insert ?
        if (i == _segcount) {
            // Append
            if ((++_segcount) > segments.length)
                ensureIdxAvail(segments.length*2);
            segments[i] = onew;
        } else if (segments[i].start <= anew.end) {
            // Update
            segments[i] |= onew;
        } else {
            // Insert, need to ensure we have space, and shift trailing segments up a position
            if (++_segcount > segments.length)
                ensureIdxAvail(segments.length*2);
            for (auto j=_segcount;j>i;j--)
                segments[j] = segments[j-1];
            segments[i] = onew;
        }

        // Squash possible trails (merge any intersecting or adjacent segments)
        uint j = i+1;
        for (;(j < _segcount) && (segments[j].start <= (segments[i].end+1)); j++)
            segments[i] |= segments[j];

        // Right-shift the rest
        uint shift = j-i-1;
        if (shift) {
            _segcount -= shift; // New _segcount
            // Shift down valid segments
            for (i+=1; i < _segcount; i++)
                segments[i] = segments[i+shift];
            // Zero-fill superfluous segments
            for (;shift; shift--)
                segments[i++] = Segment.init;
        }
    }

    /************************************************************************************
     * Ensure underlying file is up-to-date
     ***********************************************************************************/
    void flush() {
        file.flush();
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
        auto path = new FilePath("/tmp/bh-unittest-testmap");
        void cleanup() {
            if (path.exists)
                path.remove();
        }
        cleanup();
        scope(exit) cleanup();

        auto map = new CacheMap(path);
        map.add(0,15);
        assert(map.segments[0].start == 0);
        assert(map.segments[0].end == 15);
        map.add(30,15);
        assert(map.segments[1].start == 30);
        assert(map.segments[1].end == 45);
        assert(map.segments[2].start == 0);
        assert(map.segments[2].end == 0);
        map.add(45,5);
        assert(map.segments[1].start == 30);
        assert(map.segments[1].end == 50);
        assert(map.segments[2].start == 0);
        assert(map.segments[2].end == 0);
        map.add(25,5);
        assert(map.segments[1].start == 25);
        assert(map.segments[1].end == 50);
        assert(map.segments[2].start == 0);
        assert(map.segments[2].end == 0);

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
        assert(map.segments[2].start == 0);
        assert(map.segments[2].end == 0);

        assert(map.has(0,10) == true);
        assert(map.has(1,15) == true);
        assert(map.has(16,15) == false);
        assert(map.has(29,5) == true);
        assert(map.has(30,5) == true);
        assert(map.has(35,5) == true);
        assert(map.has(45,5) == true);
        assert(map.has(46,5) == false);
    }
}

