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
module lib.cachedalloc;

public import tango.core.Memory;
public import tango.core.sync.Mutex : Mutex;
public import tango.util.container.more.Stack : Stack;

/****************************************************************************************
 * CachedAllocation is a mixin-template for caching the allocation of classes and
 * structs. Mixing in the template into a class or struct enables faster allocation and
 * deallocation of the class, suitable for structures frequently allocated and freed.
 * NOTE: ONLY works for object explicitly freed.
 ***************************************************************************************/
template CachedAllocation(uint CacheSize, size_t AllocSize) {
static:
    static Mutex _allocation_mutex;
    static Stack!(void*, CacheSize) _allocation_cache;
    static this () {
        _allocation_mutex = new Mutex();
    }
    new(size_t sz) {
        assert(sz <= AllocSize, "Error, allocating more than specified in mixin instance");
        synchronized (_allocation_mutex) {
            if (_allocation_cache.size)
                return _allocation_cache.pop();
        } // Else
        return GC.malloc(AllocSize);
    }
    delete(void * p) {
        synchronized (_allocation_mutex) {
            if (_allocation_cache.unused)
                return _allocation_cache.push(p);
        } // Else
        GC.free(p);
    }

}