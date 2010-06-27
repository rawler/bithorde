/****************************************************************************************
 * Asset MetaData used both in asset and manager.
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
module daemon.cache.metadata;

import lib.hashes;
import hex = lib.hex;
private import lib.message;
private import lib.protobuf;

/****************************************************************************************
 * AssetMetaData holds the mapping between the different ids of an asset
 ***************************************************************************************/
class AssetMetaData : ProtoBufMessage {
    mixin(PBField!(ubyte[], "localId"));        /// Local assetId
    mixin(PBField!(Identifier[], "hashIds"));   /// HashIds

    mixin ProtoBufCodec!(PBMapping("localId",   1),
                         PBMapping("hashIds",   2));

    char[] toString() {
        char[] retval = "AssetMetaData {\n";
        retval ~= "     localId: " ~ hex.encode(localId) ~ "\n";
        foreach (hash; hashIds) {
            retval ~= "     " ~ HashMap[hash.type].name ~ ": " ~ hex.encode(hash.id) ~ "\n";
        }
        return retval ~ "}";
    }
}
