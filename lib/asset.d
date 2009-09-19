module lib.asset;

interface IAsset {
    ubyte[] read(ulong offset, uint length);
    ulong size();
}
