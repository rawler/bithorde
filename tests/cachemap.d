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
module tests.cachemap;

import tango.core.Exception;
import tango.io.device.Array;
import tango.io.Stdout;
import tango.util.log.AppendConsole;
import tango.util.log.LayoutDate;
import tango.util.log.Log;

import lib.message;

import daemon.cache.map;

/// Log for all the tests
static Logger LOG;

void test_roundtrip() {
    const TEST_HASH = cast(ubyte[])x"00112233445566778899AABBCCDDEEFF";
    const TEST_HASH_COUNT = 8_589_934_592L;

    synchronized (Stderr.stream) { Stderr.newline()("Testing Writing CacheMap...").newline; }
    auto map = new CacheMap();
    map.add(10,18);

    ubyte[][HashType] hashes;
    hashes[HashType.TREE_TIGER] = TEST_HASH;
    map.store_hashes(TEST_HASH_COUNT, hashes);

    scope array = new Array(0,1);
    map.write(array);
    array.seek(0);

    synchronized (Stderr.stream) { Stderr("Testing Loading CacheMap...").newline; }
    map = new CacheMap();
    map.load(array);

    synchronized (Stderr.stream) { Stderr("Verifying...").newline; }

    if ( (map.header.hashedAmount != TEST_HASH_COUNT)
        || !(HashType.TREE_TIGER in map.header.hashes)
        || (map.header.hashes[HashType.TREE_TIGER] != TEST_HASH) )
        throw new AssertException("Failed hashes-test", __FILE__, __LINE__);

    if ( (!map.has(10,18))
        || (map.has(28,1)) )
        throw new AssertException("Failed segments-test", __FILE__, __LINE__);

    synchronized (Stderr.stream) { Stderr("SUCCESS!").newline; }
}

void test_v1_load() {
    // NOTE: This test will only work on little-endian machines.
    const ubyte[] V1_store = [10, 0, 0, 0, 0, 0, 0, 0, 28, 0, 0, 0, 0, 0, 0, 0];

    auto array = new Array(V1_store.dup);
    synchronized (Stderr.stream) { Stderr.newline()("Testing Loading V1 CacheMap...").newline; }
    auto map = new CacheMap();
    map.load(array);

    synchronized (Stderr.stream) { Stderr("Verifying...").newline; }
    if ( (!map.has(10,18))
        || (map.has(28,1))
        || (map.header.ver != 2) // Data should be auto-converted to v2 on load.
        || (map.header.hashedAmount != 0) )
        throw new AssertException("Failed", __FILE__, __LINE__);

    synchronized (Stderr.stream) { Stderr("SUCCESS!").newline; }
}

/// Execute all the tests in order
void main() {
    Log.root.add(new AppendConsole(new LayoutDate));
    LOG = Log.lookup("cachemaptest");

    test_roundtrip;
    test_v1_load;
}