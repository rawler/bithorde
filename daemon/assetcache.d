module bithorde.daemon.assetcache;

private import tango.io.Stdout;
private import tango.text.convert.Format;
private import tango.io.device.Array;
private import tango.core.Exception;

class Asset
{
public:
    char[] hashtype;
    ubyte[] id;
    ulong size;

public:
    this(char[] hashtype, ubyte[] id, ulong size)
    in
    {
        assert(hashtype.length <= 8);
    }
    body
    {
        this.hashtype = hashtype;
        this.id = id;
        this.size = size;
    }

    char[] idAsHex()
    {
        static DIGITS = "0123456789abcdef";
        auto result = new Array(256);
        foreach (b; id) {
            char[2] hexChar;
            hexChar[0] = DIGITS[b >> 4];
            hexChar[1] = DIGITS[b & 0b00001111];
            result.append(hexChar);
        }
        return cast(char[])result.slice;
    }

    char[] toString()
    {
        return Format.convert("{}-{}", hashtype, idAsHex);
    }

    unittest
    {
        // Test string generation
        auto testAsset = new Asset("SHA1", cast(ubyte[])x"12ab 0418 33df daaf 2673 6e2a", 32);
        assert(testAsset.toString == "SHA1-12ab041833dfdaaf26736e2a");
    }
    unittest
    {
        // Too long hashtype should throw error
        bool threw_exception = false;
        try {
            auto testAsset2 = new Asset("SHA1asfgasf", cast(ubyte[])x"12ab 0418", 32);
        } catch (AssertException e) {
            threw_exception = true;
        }
        if (!threw_exception)
            throw new AssertException("Creating Asset with hashtype.length>8 should have generated an error",
                                      __FILE__, __LINE__);
    }
}
/*
class AssetCache
{
private:
    

public:
    Asset getAsset()
    {
        
    }

    Asset createAsset(char[8] hashtype, ubyte[] id, ulong size)
    {
        
    }
}
*/
public int main(char[][] args)
{
    auto testAsset = new Asset("SHA1", cast(ubyte[])x"12ab 0418 33df daaf 2673 6e2a", 32);

    Stdout(testAsset.toString).newline;

    return 0;
}