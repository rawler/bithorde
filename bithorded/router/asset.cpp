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
#include "router.hpp"

#include <boost/foreach.hpp>
#include <boost/smart_ptr/make_shared.hpp>
#include <utility>

#include <lib/weak_fn.hpp>
#include "lib/random.h"

#include <log4cplus/logger.h>
#include <log4cplus/loggingmacros.h>

using namespace bithorded::router;
using namespace std;

const int32_t DEFAULT_TIMEOUT_MS = 5000;

namespace bithorded { namespace router {
	log4cplus::Logger assetLogger = log4cplus::Logger::getInstance("router");
} }

void PendingRead::cancel()
{
	cb(offset, "");
}

UpstreamAsset::UpstreamAsset(const bithorde::ReadAsset::ClientPointer& client, const BitHordeIds& requestIds)
	: ReadAsset(client, requestIds)
{}

void UpstreamAsset::handleMessage(const bithorde::Read::Response& resp)
{
	auto self_ref = shared_from_this();
	bithorde::ReadAsset::handleMessage(resp);
}

ForwardedAsset::ForwardedAsset(Router& router, const BitHordeIds& ids) :
	_router(router),
	_requestedIds(ids),
	_size(-1),
	_upstream(),
	_pendingReads()
{
}

ForwardedAsset::~ForwardedAsset()
{
	for (auto iter=_pendingReads.begin(); iter != _pendingReads.end(); iter++)
		iter->cancel();
}

bool bithorded::router::ForwardedAsset::hasUpstream(const std::string peername)
{
	return _upstream.count(peername);
}

void bithorded::router::ForwardedAsset::apply(const AssetRequestParameters& old, const AssetRequestParameters& current)
{
	bool has_new_requesters = false;
	for (auto iter=current.requesters.begin(); iter != current.requesters.end(); iter++) {
		if (!old.requesters.count(*iter))
			has_new_requesters = true;
	}
	auto requesters_ = requestTrace(current.requesters);
	auto& friends = _router.connectedFriends();

	int32_t timeout(DEFAULT_TIMEOUT_MS);
	if ((status->status() == bithorde::NONE) && (!current.deadline.is_special())) {
		timeout = (current.deadline - boost::posix_time::microsec_clock::universal_time()).total_milliseconds();
	}

	for (auto iter = friends.begin(); iter != friends.end(); iter++) {
		auto f = iter->second;

		if (old.isRequester(f) || current.isRequester(f))
			continue;

		auto peername = f->peerName();
		if (_upstream.count(peername)) {
			if (current.requesters.size()) { // Some downstreams are still interested
				auto& upstream = _upstream[peername];
				auto client = upstream->client();
				client->bind(*upstream, requesters_);
			} else {
				dropUpstream(peername);
			}
		} else if (has_new_requesters) {
			auto upstream = make_shared<UpstreamAsset>(f, _requestedIds);
			auto self = boost::weak_ptr<ForwardedAsset>(shared_from_this());
			upstream->statusUpdate.connect(boost::bind(boost::weak_fn(&ForwardedAsset::onUpstreamStatus, self), peername, bithorde::ASSET_ARG_STATUS));
			upstream->dataArrived.connect(boost::bind(boost::weak_fn(&ForwardedAsset::onData, self),
				bithorde::ASSET_ARG_OFFSET, bithorde::ASSET_ARG_DATA, bithorde::ASSET_ARG_TAG));
			if (f->bind(*upstream, timeout, requesters_))
				_upstream[peername] = upstream;
		}
	}
	updateStatus();
}

void bithorded::router::ForwardedAsset::onUpstreamStatus(const string& peername, const bithorde::AssetStatus& status)
{
	if (status.status() == bithorde::Status::SUCCESS) {
		LOG4CPLUS_DEBUG(assetLogger, _requestedIds << " Found upstream " << peername);
		if (status.has_size()) {
			if (_size == -1) {
				_size = status.size();
			} else if (_size != (int64_t)status.size()) {
				LOG4CPLUS_WARN(assetLogger, peername << " " << _requestedIds << " responded with mismatching size, ignoring...");
				dropUpstream(peername);
			}
		} else if (status.ids().size()) {
			LOG4CPLUS_WARN(assetLogger, peername << " " << _requestedIds << " SUCCESS response not accompanied with asset-size.");
		}
	} else {
		LOG4CPLUS_DEBUG(assetLogger, _requestedIds << "Failed upstream " << peername);
		dropUpstream(peername);
	}
	updateStatus();
}

void bithorded::router::ForwardedAsset::updateStatus() {
	bithorde::Status status = _upstream.empty() ? bithorde::Status::NOTFOUND : bithorde::Status::NONE;
	for (auto iter=_upstream.begin(); iter!=_upstream.end(); iter++) {
		auto& asset = iter->second;
		if (asset->status == bithorde::Status::SUCCESS)
			status = bithorde::Status::SUCCESS;
	}
	auto trx = this->status.change();
	trx->set_size(_size);
	trx->set_availability(1000);
	trx->set_status(status);

	unordered_set< uint64_t > servers;
	servers.insert(sessionId());
	for (auto iter = _upstream.begin(); iter != _upstream.end(); iter++) {
		const auto& upstreamServers = iter->second->servers();
		servers.insert(upstreamServers.begin(), upstreamServers.end());
	}
	setRepeatedField(trx->mutable_servers(), servers);

	unordered_set< bithorde::Identifier > requestIds;
	for (auto iter = _upstream.begin(); iter != _upstream.end(); iter++) {
		const auto& upstreamRequestIds = iter->second->requestIds();
		for (auto iter1 = upstreamRequestIds.begin(); iter1 != upstreamRequestIds.end(); iter1++) {
			requestIds.insert(*iter1);
		}
	}
	setRepeatedPtrField(trx->mutable_ids(), requestIds);
}

size_t bithorded::router::ForwardedAsset::can_read(uint64_t offset, size_t size)
{
	return size;
}

void bithorded::router::ForwardedAsset::async_read(uint64_t offset, size_t& size, uint32_t timeout, ReadCallback cb)
{
	if (_upstream.empty())
		return cb(-1, string());
	auto chosen = _upstream.begin();
	uint32_t current_best = 1000*60*60*24;
	for (auto iter = _upstream.begin(); iter != _upstream.end(); iter++) {
		auto& a = iter->second;
		if (a->status != bithorde::SUCCESS)
			continue;
		if (current_best > a->readResponseTime.value()) {
			current_best = a->readResponseTime.value();
			chosen = iter;
		}
	}
	PendingRead read;
	read.offset = offset;
	read.size = size;
	read.cb = cb;
	_pendingReads.push_back(read);
	chosen->second->aSyncRead(offset, size, timeout);
}

void bithorded::router::ForwardedAsset::onData(uint64_t offset, const std::string& data, int tag) {
	for (auto iter=_pendingReads.begin(); iter != _pendingReads.end(); ) {
		if (iter->offset == offset) {
			iter->cb(offset, data);
			iter = _pendingReads.erase(iter); // Will increase the iterator
		} else {
			iter++;	// Move to next
		}
	}
}

uint64_t bithorded::router::ForwardedAsset::size()
{
	return _size;
}

void ForwardedAsset::inspect(bithorded::management::InfoList& target) const
{
	target.append("type") << "forwarded";
}

void ForwardedAsset::inspect_upstreams(bithorded::management::InfoList& target) const
{
	for (auto iter = _upstream.begin(); iter != _upstream.end(); iter++) {
		ostringstream buf;
		buf << "upstream_" << iter->first;
		target.append(buf.str()) << bithorde::Status_Name(iter->second->status) << ", responseTime: " << iter->second->readResponseTime;
	}
}


void ForwardedAsset::dropUpstream(const string& peername)
{
	auto upstream = _upstream.find(peername);
	if (upstream != _upstream.end()) {
		upstream->second->statusUpdate.disconnect(boost::bind(&ForwardedAsset::onUpstreamStatus, this, peername, bithorde::ASSET_ARG_STATUS));
		upstream->second->dataArrived.disconnect(boost::bind(&ForwardedAsset::onData, this,
			bithorde::ASSET_ARG_OFFSET, bithorde::ASSET_ARG_DATA, bithorde::ASSET_ARG_TAG));
		_upstream.erase(upstream);
	}
}

bithorde::RouteTrace ForwardedAsset::requestTrace(const std::unordered_set<uint64_t>& requesters) const
{
	bithorde::RouteTrace requesters_;
	requesters_.Add(sessionId());
	for (auto iter=requesters.begin(); iter != requesters.end(); iter++) {
		requesters_.Add(*iter);
	}
	return requesters_;
}
