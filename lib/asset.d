module lib.asset;

enum BHStatusCode {
    SUCCESS = 1,
    NOTFOUND = 2,
}

import lib.client;

alias void delegate(IAsset, BHStatusCode status) BHOpenCallback;
alias void delegate(IAsset, ulong offset, ubyte[], BHStatusCode status) BHReadCallback;

interface IAsset {
    void aSyncRead(ulong offset, uint length, BHReadCallback);
    ulong size();
}
