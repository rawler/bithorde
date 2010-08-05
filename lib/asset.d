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
 ***************************************************************************************/
module lib.asset;

public import tango.core.Signal;
public import tango.core.Traits;

import lib.message;

alias ushort  AssetHandle;

/****************************************************************************************
 * Definitition of a BitHorde asset
 ***************************************************************************************/
interface IAsset {
    void aSyncRead(ulong offset, uint length, BHReadCallback);
    ulong size();
    void close();
    Signal!(ParameterTupleOf!(BHAssetStatusCallback))* statusSignal();
    template StatusSignal() {
        protected Signal!(ParameterTupleOf!(BHAssetStatusCallback)) _statusSignal;

        public Signal!(ParameterTupleOf!(BHAssetStatusCallback))* statusSignal() {
            return &_statusSignal;
        }
    }
}

/// Callbacks for requests
alias void delegate(IAsset, Status status, AssetStatus) BHAssetStatusCallback;
alias void delegate(IAsset, Status status, ReadRequest, ReadResponse) BHReadCallback;
alias void delegate(IAsset, Status status, MetaDataRequest, MetaDataResponse) BHMetaDataCallback;

