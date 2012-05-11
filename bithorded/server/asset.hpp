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
#include <boost/signals2/signal.hpp>

#include <lib/hashes.h>
#include <lib/types.h>

namespace bithorded
{

class Asset
{
public:
	typedef boost::function<void(int64_t offset, const std::string& data)> ReadCallback;

	bithorde::Status status;
	boost::signals2::signal<void(const bithorde::Status&)> statusChange;
	Asset() : status(bithorde::Status::NONE)
	{}

	typedef boost::shared_ptr<Asset> Ptr;

	virtual void async_read(uint64_t offset, size_t& size, ReadCallback cb) = 0;
	virtual uint64_t size() = 0;
	virtual size_t can_read(uint64_t offset, size_t size) = 0;
	virtual bool getIds(BitHordeIds& ids) = 0;

protected:
	void setStatus(bithorde::Status newStatus);
};

}

#endif // BITHORDED_ASSET_HPP
