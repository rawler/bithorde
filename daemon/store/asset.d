/****************************************************************************************
 * Asset MetaData used both in asset and manager.
 *
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
module daemon.store.asset;

private import tango.time.Time;
private import tango.util.Convert;

private import lib.asset;
private import lib.hashes;
private import hex = lib.hex;
private import lib.message;
private import lib.protobuf;

/****************************************************************************************
 * BaseAsset forms the base for extending a stored file with rating and hashIds.
 ***************************************************************************************/
class BaseAsset {
    mixin(PBField!(Identifier[], "hashIds"));   /// HashIds
    mixin(PBField!(ulong, "size"));             /// Total size of asset
}
