/****************************************************************************************
 * Asset MetaData used both in asset and manager.
 *
 * Copyright: Ulrik Mikaelsson, All rights reserved
 ***************************************************************************************/
module daemon.cache.common;

import lib.hashes;
import hex = lib.hex;
import message = lib.message;
private import lib.protobuf;

/****************************************************************************************
 * AssetMetaData holds the mapping between the different ids of an asset
 ***************************************************************************************/
class AssetMetaData : ProtoBufMessage {
    ubyte[] localId;                /// Local assetId
    message.Identifier[] hashIds;   /// HashIds

    mixin MessageMixin!(PBField!("localId",   1)(),
                        PBField!("hashIds",   2)());

    char[] toString() {
        char[] retval = "AssetMetaData {\n";
        retval ~= "     localId: " ~ hex.encode(localId) ~ "\n";
        foreach (hash; hashIds) {
            retval ~= "     " ~ HashMap[hash.type].name ~ ": " ~ hex.encode(hash.id) ~ "\n";
        }
        return retval ~ "}";
    }
}
