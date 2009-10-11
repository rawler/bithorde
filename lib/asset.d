module lib.asset;

import lib.message;

interface IAsset {
    void aSyncRead(ulong offset, uint length, BHReadCallback);
    ulong size();
}

alias void delegate(IAsset, Status status) BHOpenCallback;
alias void delegate(IAsset, ulong offset, ubyte[], Status status) BHReadCallback;

