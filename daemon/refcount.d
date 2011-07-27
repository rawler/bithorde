/****************************************************************************************
 * All the different variants of Cache-Assets
 *
 *   Copyright: Copyright (C) 2009-2011 Ulrik Mikaelsson. All rights reserved
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

module daemon.refcount;

interface IRefCounted {
    void takeRef(Object);
    void dropRef(Object);
}

struct References {
    private Object[] refs;
    bool add(Object o) {
        foreach (r; refs) if (r == o)
            return false;
        refs ~= o;
        return true;
    }

    bool remove(Object o) {
        foreach (i,r; refs) {
            if (r is o) {
                foreach (a, ref b; refs[i..$-1])
                    b = refs[i+1];
                refs.length = refs.length - 1;
                return true;
            }
        }
        return false;
    }

    size_t length() {
        return refs.length;
    }
}

template RefCountTarget() {
    private References refs;
    void takeRef(Object o) {
        refs.add(o);
    }

    void dropRef(Object o) {
        refs.remove(o);
        if (refs.length == 0)
            close();
    }
}
