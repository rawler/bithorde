module lib.asset;

interface IAsset {
    ubyte[] read(ulong offset, uint length);
    long length();
}

class RemoteAsset {
    // TODO
}