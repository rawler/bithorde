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
#include <boost/make_shared.hpp>

using namespace bithorded;

/**** AssetBinding *****/

AssetBinding::AssetBinding() :
	_client(NULL),
	_ptr(),
	_requesters(),
	_deadline(boost::posix_time::neg_infin)
{}

AssetBinding::AssetBinding(const AssetBinding& other) :
	_client(other._client),
	_ptr(other._ptr),
	_requesters(other._requesters),
	_deadline(other.deadline())
{
	if (_ptr) {
		_ptr->bindDownstream(this);
	}
}

AssetBinding::~AssetBinding()
{
	reset();
}

void AssetBinding::setClient(const boost::shared_ptr< Client >& client)
{
	_client = client.get();
}

Client* AssetBinding::client() const
{
	return _client;
}

bool AssetBinding::bind(const bithorde::RouteTrace& requesters)
{
	return bind(_ptr, requesters, boost::posix_time::neg_infin);
}

bool AssetBinding::bind(const boost::shared_ptr< UpstreamRequestBinding >& asset, const bithorde::RouteTrace& requesters, const boost::posix_time::ptime& deadline)
{
	if (_ptr) {
		if (asset != _ptr)
			_ptr->unbindDownstream(this);
	}
	_requesters = requesters;
	_deadline = deadline;
	if (_requesters.size() == 0)
		_requesters.Add(rand64());
	if (asset->bindDownstream(this)) {
		if (asset != _ptr)
			_ptr = asset;
		return true;
	} else {
		reset();
		return false;
	}
}

void AssetBinding::reset()
{
	if (_ptr) {
		_ptr->unbindDownstream(this);
	}
	_ptr.reset();
	_requesters.Clear();
	_deadline = boost::posix_time::neg_infin;
}

AssetBinding& AssetBinding::operator=(const AssetBinding& other)
{
	if (_ptr) {
		_ptr->unbindDownstream(this);
	}
	_ptr = other._ptr;
	_requesters = other._requesters;
	if (_ptr) {
		_ptr->bindDownstream(this);
	}
	return *this;
}

IAsset* AssetBinding::get() const
{
	if (_ptr)
		return _ptr->get();
	else
		return NULL;
}

IAsset& AssetBinding::operator*() const
{
	return _ptr->operator*();
}

IAsset* AssetBinding::operator->() const
{
	return get();
}

AssetBinding::operator bool() const
{
	return _ptr.get() && _ptr->get();
}

const boost::shared_ptr< IAsset >& AssetBinding::shared() const
{
	if (_ptr) {
		return _ptr->shared();
	} else {
		return IAsset::NONE;
	}
}

boost::weak_ptr< IAsset > AssetBinding::weak() const
{
	if (_ptr) {
		return _ptr->weaken();
	} else {
		return boost::weak_ptr< IAsset >();
	}
}

bool bithorded::operator==(const AssetBinding& a, const boost::shared_ptr< IAsset >& b)
{
	return a.get() == b.get();
}

bool bithorded::operator!=(const AssetBinding& a, const boost::shared_ptr< IAsset >& b)
{
	return a.get() != b.get();
}

void AssetBinding::clearDeadline()
{
	_deadline = boost::posix_time::neg_infin;
	if (_ptr) {
		_ptr->bindDownstream(this);
	}
}

/**** AssetRequestParameters *****/
bool AssetRequestParameters::isRequester(const boost::shared_ptr< Client >& client) const
{
	return requesterClients.count(client.get());
}

bool AssetRequestParameters::operator!=(const AssetRequestParameters& other) const
{
	return (this->requesters != other.requesters);
}

/**** UpstreamRequestBinding *****/
UpstreamRequestBinding::Ptr UpstreamRequestBinding::NONE;

UpstreamRequestBinding::UpstreamRequestBinding(boost::shared_ptr< IAsset > asset) :
	_ptr(asset), _parameters(), _downstreams()
{}

bool UpstreamRequestBinding::bindDownstream(const AssetBinding* binding)
{
	const auto& servers_ = _ptr->status->servers();
	std::unordered_set<uint64_t> servers(servers_.begin(), servers_.end());
	const auto& requesters_ = binding->requesters();
	for (auto iter=requesters_.begin(); iter != requesters_.end(); iter++) {
		if (servers.count(*iter)) {
			return false;
		}
	}
	_downstreams.insert(binding);
	rebuild();
	return true;
}

void UpstreamRequestBinding::unbindDownstream(const AssetBinding* binding)
{
	_downstreams.erase(binding);
	rebuild();
}

IAsset* UpstreamRequestBinding::get() const
{
	return _ptr.get();
}

IAsset& UpstreamRequestBinding::operator*() const
{
	return _ptr.operator*();
}

IAsset* UpstreamRequestBinding::operator->() const
{
	return _ptr.operator->();
}

const boost::shared_ptr< IAsset >& UpstreamRequestBinding::shared()
{
	return _ptr;
}

boost::weak_ptr< IAsset > UpstreamRequestBinding::weaken()
{
	return boost::weak_ptr<IAsset>(_ptr);
}

void UpstreamRequestBinding::rebuild()
{
	auto& deadline = _parameters.deadline;
	auto& requesters = _parameters.requesters;
	auto& requesterClients = _parameters.requesterClients;
	auto old = _parameters;
	deadline = boost::posix_time::neg_infin;
	requesters.clear();
	requesterClients.clear();
	for (auto iter=_downstreams.begin(); iter != _downstreams.end(); iter++) {
		const auto& downstream_requesters = (*iter)->requesters();
		requesters.insert(downstream_requesters.begin(), downstream_requesters.end());
		requesterClients.insert((*iter)->client());
		auto currentDeadline = (*iter)->deadline();
		if (currentDeadline > deadline)
			deadline = currentDeadline;
	}
	if (old != _parameters) {
		_ptr->apply(old, _parameters);
	}
}

/**** IAsset *****/
IAsset::Ptr IAsset::NONE;

IAsset::IAsset() :
	_sessionId(rand64())
{}

void IAsset::describe(bithorded::management::Info& target) const
{
	target << bithorde::Status_Name(status->status());
	if (status->ids_size())
		target << ", " << status->ids();
}
