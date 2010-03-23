/****************************************************************************************
 *   Copyright: Copyright (C) 2009-2010 Ulrik Mikaelsson. All rights reserved
 *
 *   License:
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **************************************************************************************/
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

