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

import daemon.cache.map;

/// Log for all the tests
static Logger LOG;

/// Execute all the tests in order
void main() {
    Log.root.add(new AppendConsole(new LayoutDate));
    LOG = Log.lookup("cachemaptest");

    synchronized (Stderr.stream) { Stderr("\nTesting Writing CacheMap\n=====================\n").newline; }
    auto map = new CacheMap();
    map.add(10,18);
    scope array = new Array(0,1);
    map.write(array);
    array.seek(0);

    synchronized (Stderr.stream) { Stderr("\nTesting Loading CacheMap\n=====================\n").newline; }
    map = new CacheMap();
    map.load(array);

    synchronized (Stderr.stream) { Stderr("\nVerifying\n=====================\n").newline; }
    if ( (!map.has(10,18)) ||
         map.has(28,1) )
        throw new AssertException("Failed", __FILE__, __LINE__);

    synchronized (Stderr.stream) { Stderr("\nSUCCESS!\n").newline; }
}