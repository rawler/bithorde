module lib.asset;

import lib.message;

alias void delegate(IAsset, BHStatus status) BHOpenCallback;
alias void delegate(IAsset, ulong offset, ubyte[], BHStatus status) BHReadCallback;

interface IAsset {
    void aSyncRead(ulong offset, uint length, BHReadCallback);
    ulong size();
}
