/*
    Copyright 2012 Ulrik Mikaelsson <ulrik.mikaelsson@gmail.com>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
*/


#include "asset.hpp"

using namespace std;

using namespace bithorded;
using namespace bithorded::source;

SourceAsset::SourceAsset(GrandCentralDispatch& gcd, const boost::filesystem::path& metaFolder) :
	StoredAsset(gcd, metaFolder, RandomAccessFile::READ)
{
	setStatus(bithorde::SUCCESS);
}

void SourceAsset::inspect(management::InfoList& target) const
{
	target.append("type") << "SourceAsset";
	target.append("path") << _file.path();
}
