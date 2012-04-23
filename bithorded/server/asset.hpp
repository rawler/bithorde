/*
    Copyright 2012 <copyright holder> <email>

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


#ifndef BITHORDED_ASSET_HPP
#define BITHORDED_ASSET_HPP

#include <boost/shared_ptr.hpp>
#include <boost/function.hpp>

#include <lib/hashes.h>
#include <lib/types.h>

namespace bithorded
{

class Asset
{
public:
	typedef boost::shared_ptr<Asset> Ptr;
	typedef boost::function<void(Asset::Ptr)> Target;

	virtual const byte* read(uint64_t offset, size_t& size, byte* buf) = 0;
	virtual uint64_t size() = 0;
	virtual size_t can_read(uint64_t offset, size_t size) = 0;
	virtual bool getIds(BitHordeIds& ids) = 0;
};

}

#endif // BITHORDED_ASSET_HPP
