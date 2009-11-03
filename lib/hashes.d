module lib.hashes;

private import tango.io.device.Array;
private import tango.io.stream.Format;

public import dcrypt.crypto.Hash;
private import dcrypt.crypto.hashes.SHA1;
private import dcrypt.crypto.hashes.SHA256;
private import dcrypt.crypto.hashes.ED2K;
private import dcrypt.crypto.hashes.Tiger;
private import dcrypt.crypto.TreeHash;
private import dcrypt.misc.ByteConverter;

private import lib.message;

/**
 * The only function anyone need, really ;)
 */
Hash hashFactory(TYPE:Hash)() {
    return new TYPE;
}

char[] base32NoPad(void[] input) {
    return ByteConverter.base32Encode(input, false);
}

struct HashDetail {
    HashType pbType;
    char[] name;
    Hash function() factory;
    char[] function(void[]) magnetFormatter;
}

HashDetail[HashType] HashMap;

static this() {
    auto hashes = [HashDetail(HashType.SHA1, "sha1", &hashFactory!(SHA1), &base32NoPad),
                   HashDetail(HashType.SHA256, "sha256", &hashFactory!(SHA256), &base32NoPad),
                   HashDetail(HashType.TREE_TIGER, "tree:tiger", &hashFactory!(TreeHash!(Tiger)), &base32NoPad),
                   HashDetail(HashType.ED2K, "ed2k", &hashFactory!(ED2K), &base32NoPad)];
    foreach (h; hashes)
        HashMap[h.pbType] = h;
}

char[] formatMagnet(Identifier[] ids, ulong length) {
    scope auto array = new Array(64,64);
    scope auto format = new FormatOutput!(char)(array);
    format.format("magnet:");
    foreach (id; ids) {
        auto hash = HashMap[id.type];
        format.format("&xt=urn:{}:{}", hash.name, hash.magnetFormatter(id.id));
    }
    format.format("&xl={}", length);
    format.flush();
    return cast(char[])array.slice;
}

char[] formatED2K(Identifier[] ids, ulong length) {
    scope auto array = new Array(64,64);
    scope auto format = new FormatOutput!(char)(array);
    ubyte[] hash;
    foreach (id; ids) {
        if (id.type == HashType.ED2K) {
            hash = id.id;
            break;
        }
    }
    format.format("ed2k://|file||{}|{}|/", length, ByteConverter.hexEncode(hash));
    format.flush();
    return cast(char[])array.slice;
}