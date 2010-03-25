/****************************************************************************************
 * Implementation of all the BitHorde-supported Hashes
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
 ***************************************************************************************/
module lib.hashes;

private import tango.io.device.Array;
private import tango.text.convert.Format;
private import tango.text.Regex;

public import tango.util.digest.Digest;
private import tango.util.digest.Sha1;
private import tango.util.digest.Sha256;
private import tango.util.digest.Tiger;

private static import base32 = lib.base32;
private static import hex = lib.hex;
private import lib.digest.ED2K;
private import lib.digest.HashTree;
private import lib.message;

/****************************************************************************************
 * The only function anyone need, really ;)
 ***************************************************************************************/
Digest hashFactory(TYPE:Digest)() {
    return new TYPE;
}

/****************************************************************************************
 * Wrapper for bas32 without padding
 ***************************************************************************************/
char[] base32NoPad(ubyte[] input) {
    return base32.encode(input, false);
}

/****************************************************************************************
 * Structure for details of each configured Hash.
 ***************************************************************************************/
struct HashDetail {
    HashType pbType;
    char[] name;
    Digest function() factory;
    char[] function(ubyte[]) magnetFormatter;
    ubyte[] function(char[]) magnetDeformatter;
}

HashDetail[HashType] HashMap;

/****************************************************************************************
 * Statically configure supported HashType:s
 ***************************************************************************************/
static this() {
    auto hashes = [
        HashDetail(HashType.SHA1, "sha1", &hashFactory!(Sha1), &base32NoPad, &base32.decode),
        HashDetail(HashType.SHA256, "sha256", &hashFactory!(Sha256), &base32NoPad, &base32.decode),
        HashDetail(HashType.TREE_TIGER, "tree:tiger", &hashFactory!(HashTree!(Tiger)), &base32NoPad, &base32.decode),
        HashDetail(HashType.ED2K, "ed2k", &hashFactory!(ED2K), &base32NoPad, &base32.decode),
    ];
    foreach (h; hashes)
        HashMap[h.pbType] = h;
}

/****************************************************************************************
 * Format asset details into Magnet URI.
 ***************************************************************************************/
char[] formatMagnet(Identifier[] ids, ulong length, char[] name = null)
in {
    assert(ids.length > 0);
} body {
    scope auto array = new Array(64,64);
    array.write("magnet:?");
    uint idx;
    void append(char[] fmt, ...) {
        if (idx++)
            array.write("&");
        Format.convert(cast(uint delegate(char[]))&array.write, _arguments, _argptr, fmt);
    }
    if (name)
        append("dn={}", name);
    append("xl={}", length);
    foreach (id; ids) {
        auto hash = HashMap[id.type];
        append("xt=urn:{}:{}", hash.name, hash.magnetFormatter(id.id));
    }
    return cast(char[])array.slice;
}

/****************************************************************************************
 * Format asset details into ED2K URI.
 ***************************************************************************************/
char[] formatED2K(Identifier[] ids, ulong length, char[] name = null) {
    ubyte[] hash;
    foreach (id; ids) {
        if (id.type == HashType.ED2K) {
            hash = id.id;
            break;
        }
    }
    if (hash)
        return Format.convert("ed2k://|file|{}|{}|{}|/", name?name:"", length, hex.encode(hash));
    else
        return null;
}

/****************************************************************************************
 * Parse any supported URI-format
 ***************************************************************************************/
Identifier[] parseUri(char[] uri, out char[] name) {
    auto retVal = parseMagnet(uri, name);
    if (!retVal)
        retVal = parseED2K(uri, name);
    return retVal;
}

/****************************************************************************************
 * Parse magnet-URI:s
 ***************************************************************************************/
Identifier[] parseMagnet(char[] magnetUri, out char[] name) {
    Identifier[] retVal;
    auto name_re = Regex(r"dn=([^&]+)");
    foreach (m; name_re.search(magnetUri))
        name = m[1];
    foreach (hash; HashMap) {
        auto hash_re = Regex(r"xt=urn:"~hash.name~r":(\w+)");
        foreach (m; hash_re.search(magnetUri))
            retVal ~= new Identifier(hash.pbType, hash.magnetDeformatter(m[1]));
    }
    return retVal;
}

/****************************************************************************************
 * Parse ED2K-URI:s.
 ***************************************************************************************/
Identifier[] parseED2K(char[] ed2kUri, out char[] name) {
    Identifier[] retVal;
    auto re = Regex(r"ed2k://\|file\|(.*)\|.*\|([0-9A-Fa-f]+)\|");
    foreach (m; re.search(ed2kUri)) {
        name = m[1];
        retVal ~= new Identifier(HashType.ED2K, hex.decode(m[2]));
    }
    return retVal;
}
