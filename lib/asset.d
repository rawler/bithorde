module lib.asset;

import lib.message;

alias ubyte[] AssetId;
alias ushort  AssetHandle;

interface IAsset {
    void aSyncRead(ulong offset, uint length, BHReadCallback);
    ulong size();
    HashType hashType();
    AssetId id();
}

alias void delegate(IAsset, Status status) BHOpenCallback;
alias void delegate(IAsset, ulong offset, ubyte[], Status status) BHReadCallback;
alias void delegate(IAsset, MetaDataResponse response) BHMetaDataCallback;

