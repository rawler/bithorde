module lib.asset;

import lib.message;

alias ubyte[] AssetId;
alias ushort  AssetHandle;

interface IAsset {
    void aSyncRead(ulong offset, uint length, BHReadCallback);
    ulong size();
    void close();
}

alias void delegate(IAsset, Status status, OpenOrUploadRequest, OpenResponse) BHOpenCallback;
alias void delegate(IAsset, Status status, ReadRequest, ReadResponse) BHReadCallback;
alias void delegate(IAsset, Status status, MetaDataRequest, MetaDataResponse) BHMetaDataCallback;

