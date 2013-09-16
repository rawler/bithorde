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


#include "asset.hpp"

#include <lib/random.h>

using namespace bithorded;

AssetBinding::AssetBinding() :
	boost::shared_ptr<IAsset>(),
	_requesters()
{}

AssetBinding::AssetBinding(const AssetBinding& other) :
	boost::shared_ptr<IAsset>(other),
	_requesters(other._requesters)
{
	if (auto ptr = get()) {
		ptr->bindDownstream(this);
	}
}

AssetBinding::~AssetBinding()
{
	reset();
}

bool AssetBinding::bind(const bithorde::RouteTrace& requesters)
{
	return bind(*this, requesters);
}

bool AssetBinding::bind(const boost::shared_ptr< IAsset >& asset, const bithorde::RouteTrace& requesters)
{
	if (auto ptr = get()) {
		if (asset != *this)
			ptr->unbindDownstream(this);
	}
	_requesters = requesters;
	if (_requesters.size() == 0)
		_requesters.Add(rand64());
	if (asset->bindDownstream(this)) {
		if (asset != *this)
			boost::shared_ptr<IAsset>::operator=(asset);
		return true;
	} else {
		reset();
		return false;
	}
}

void AssetBinding::reset()
{
	if (auto ptr = get()) {
		ptr->unbindDownstream(this);
	}
	shared_ptr::reset();
	_requesters.Clear();
}

AssetBinding& AssetBinding::operator=(const AssetBinding& other)
{
	if (auto ptr = get()) {
		ptr->unbindDownstream(this);
	}
	boost::shared_ptr<IAsset>::operator=(other);
	_requesters = other._requesters;
	if (auto ptr = get()) {
		ptr->bindDownstream(this);
	}
	return *this;
}

bool bithorded::operator==(const AssetBinding& a, const boost::shared_ptr< IAsset >& b)
{
	return a.get() == b.get();
}

bool bithorded::operator!=(const AssetBinding& a, const boost::shared_ptr< IAsset >& b)
{
	return a.get() != b.get();
}

IAsset::IAsset() :
	_sessionId(rand64()),
	status(bithorde::Status::NONE)
{}

std::unordered_set< uint64_t > IAsset::servers() const
{
	std::unordered_set<uint64_t> res;
	res.insert(_sessionId);
	return res;
}

bool IAsset::bindDownstream(const AssetBinding* binding)
{
	_downstreams.insert(binding);
	rebuildRequesters();
	return true;
}

void IAsset::unbindDownstream(const AssetBinding* binding)
{
	_downstreams.erase(binding);
	rebuildRequesters();
}

const std::unordered_set< const AssetBinding* >& IAsset::downstreams() const
{
	return _downstreams;
}

void IAsset::setStatus(bithorde::Status newStatus)
{
	status = newStatus;
	statusChange(newStatus);
}

void IAsset::describe(bithorded::management::Info& target) const
{
	BitHordeIds ids;
	target << bithorde::Status_Name(status);
	if (getIds(ids))
		target << ", " << ids;
}

void IAsset::rebuildRequesters()
{
	auto trx = requesters.change();
	trx->clear();
	for (auto iter=_downstreams.begin(); iter != _downstreams.end(); iter++) {
		const auto& downstream_requesters = (*iter)->requesters();
		trx->insert(downstream_requesters.begin(), downstream_requesters.end());
	}
}
