module lib.hashes;

private import tango.io.device.Array;
private import tango.text.convert.Format;
private import tango.text.Regex;

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
    ubyte[] function(char[]) magnetDeformatter;
}

HashDetail[HashType] HashMap;

static this() {
    auto hashes = [HashDetail(HashType.SHA1, "sha1", &hashFactory!(SHA1), &base32NoPad, &ByteConverter.base32Decode),
                   HashDetail(HashType.SHA256, "sha256", &hashFactory!(SHA256), &base32NoPad, &ByteConverter.base32Decode),
                   HashDetail(HashType.TREE_TIGER, "tree:tiger", &hashFactory!(TreeHash!(Tiger)), &base32NoPad, &ByteConverter.base32Decode),
                   HashDetail(HashType.ED2K, "ed2k", &hashFactory!(ED2K), &base32NoPad, &ByteConverter.base32Decode)];
    foreach (h; hashes)
        HashMap[h.pbType] = h;
}

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

char[] formatED2K(Identifier[] ids, ulong length, char[] name = null) {
    ubyte[] hash;
    foreach (id; ids) {
        if (id.type == HashType.ED2K) {
            hash = id.id;
            break;
        }
    }
    if (hash)
        return Format.convert("ed2k://|file|{}|{}|{}|/", name?name:"", length, ByteConverter.hexEncode(hash));
    else 
        return null;
}

Identifier[] parseUri(char[] uri, out char[] name) {
    auto retVal = parseMagnet(uri, name);
    if (!retVal)
        retVal = parseED2K(uri, name);
    return retVal;
}

Identifier[] parseMagnet(char[] magnetUri, out char[] name) {
    Identifier[] retVal;
    auto name_re = Regex(r"dn=([^&]+)");
    foreach (m; name_re.search(magnetUri))
        name = m[1];
    foreach (hash; HashMap) {
        auto hash_re = Regex(r"xt=urn:"~hash.name~r":(\w+)");
        foreach (m; hash_re.search(magnetUri)) {
            auto newid = new Identifier;
            newid.type = hash.pbType;
            newid.id = hash.magnetDeformatter(m[1]);
            retVal ~= newid;
        }
    }
    return retVal;
}

Identifier[] parseED2K(char[] ed2kUri, out char[] name) {
    Identifier[] retVal;
    auto re = Regex(r"ed2k://\|file\|([^\|]*)\|\d*\|(\w+)\|");
    foreach (m; re.search(ed2kUri)) {
        name = m[1];

        auto newid = new Identifier;
        newid.type = HashType.ED2K;
        newid.id = ByteConverter.hexDecode(m[2]);
        retVal ~= newid;
    }
    return retVal;
}
