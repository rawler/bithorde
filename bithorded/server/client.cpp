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

#include "client.hpp"

#include <boost/assert.hpp>
#include <iostream>

#include <log4cplus/logger.h>
#include <log4cplus/loggingmacros.h>

#include "server.hpp"
#include "../../lib/magneturi.h"
#include "../../lib/random.h"

const size_t MAX_ASSETS = 1024;
const size_t MAX_CHUNK = 64*1024;

using namespace std;
namespace fs = boost::filesystem;

using namespace bithorded;

namespace bithorded {
	log4cplus::Logger clientLogger = log4cplus::Logger::getInstance("client");
}

Client::Client( Server& server) :
	bithorde::Client(server.ioService(), server.name()),
	_server(server)
{
}

size_t Client::serverAssets() const
{
	size_t res = 0;
	for (auto iter = _assets.begin(); iter != _assets.end(); iter++) {
		if (*iter)
			res++;
	}
	return res;
}

void Client::describe(management::Info& tgt) const
{
	tgt << '+' << clientAssets().size() << '-' << serverAssets()
		<< ", incoming: " << stats->incomingBitrateCurrent.autoScale()
		<< ", outgoing: " << stats->outgoingBitrateCurrent.autoScale();
}

void Client::inspect(management::InfoList& tgt) const
{
	tgt.append("incomingCurrent") << stats->incomingBitrateCurrent.autoScale() << ", " << stats->incomingMessagesCurrent.autoScale();
	tgt.append("outgoingCurrent") << stats->outgoingBitrateCurrent.autoScale() << ", " << stats->outgoingMessagesCurrent.autoScale();
	tgt.append("incomingTotal") << stats->incomingBytes.autoScale() << ", " << stats->incomingMessages.autoScale();
	tgt.append("outgoingTotal") << stats->outgoingBytes.autoScale() << ", " << stats->outgoingMessages.autoScale();
	tgt.append("assetResponseTime") << assetResponseTime;
	for (auto iter=clientAssets().begin(); iter != clientAssets().end(); iter++) {
		ostringstream name;
		name << '+' << iter->first;
		auto& node = tgt.append(name.str());
		if (auto asset = iter->second->readAsset())
			node << bithorde::Status_Name(asset->status) << ", " << asset->requestIds();
		else
			node << "<stale>";
	}
	for (size_t i=0; i < _assets.size(); i++) {
		if (auto& asset = _assets[i]) {
			ostringstream name;
			name << '-' << i;
			tgt.append(name.str(), *asset);
		}
	}
}

void Client::onMessage(const bithorde::HandShake& msg)
{
	if (!(state() & SaidHello)) {
		auto client_config = _server.getClientConfig(msg.name());
		setSecurity(client_config.key, (bithorde::CipherType)client_config.cipher);
		sayHello();
	}
	LOG4CPLUS_INFO(clientLogger, "Connected: " << msg.name());
	bithorde::Client::onMessage(msg);
}

void Client::onMessage(const bithorde::BindWrite& msg)
{
	auto h = msg.handle();
	if ((_assets.size() > h) && _assets[h]) {
		clearAsset(h);
	}
	if (msg.has_linkpath()) {
		fs::path path(msg.linkpath());
		if (path.is_absolute()) {
			if (auto asset = _server.async_linkAsset(path)) {
				LOG4CPLUS_INFO(clientLogger, "Linking " << path);
				assignAsset(msg.handle(), asset, bithorde::RouteTrace(), boost::posix_time::neg_infin);
			} else {
				LOG4CPLUS_ERROR(clientLogger, "Upload did not match any allowed assetStore: " << path);
				informAssetStatus(msg.handle(), bithorde::ERROR);
			}
		} else {
			LOG4CPLUS_ERROR(clientLogger, "Relative links not supported" << path);
			informAssetStatus(msg.handle(), bithorde::ERROR);
		}
	} else {
		if (auto asset = _server.prepareUpload(msg.size())) {
			LOG4CPLUS_INFO(clientLogger, "Ready for upload");
			assignAsset(msg.handle(), asset, bithorde::RouteTrace(), boost::posix_time::neg_infin);
		} else {
			informAssetStatus(msg.handle(), bithorde::NORESOURCES);
		}
	}
}

void Client::onMessage(bithorde::BindRead& msg)
{
	auto h = msg.handle();

	if (msg.ids_size() > 0) {
		// Trying to open
		LOG4CPLUS_DEBUG(clientLogger, peerName() << ':' << h << " requested: " << MagnetURI(msg));
	}

	if ((_assets.size() > h) && _assets[h]) {
		auto& asset = _assets[h];
		if (idsOverlap(asset->status->ids(), msg.ids())) {
			if (asset.bind(msg.requesters())) {
				informAssetStatusUpdate(h, asset.weak(), *(asset->status));
			} else {
				informAssetStatus(h, bithorde::WOULD_LOOP);
			}
			return;
		} else {
			clearAsset(h);
		}
	}

	if (msg.ids_size() > 0) {
		// Trying to open
		try {
			auto asset = _server.async_findAsset(msg);
			if (asset) {
				boost::posix_time::ptime deadline(boost::posix_time::neg_infin);
				if (msg.has_timeout()) {
					auto now = boost::posix_time::microsec_clock::universal_time();
					deadline = now + boost::posix_time::milliseconds(msg.timeout());
				}
				assignAsset(h, asset, msg.requesters(), deadline);
			} else {
				informAssetStatus(h, bithorde::NOTFOUND);
			}
		} catch (bithorded::BindError e) {
			informAssetStatus(h, e.status);
		}
	} else {
		// Trying to close
		informAssetStatus(h, bithorde::NOTFOUND);
	}
}

void Client::onMessage(const bithorde::Read::Request& msg)
{
	const AssetBinding& asset = getAsset(msg.handle());
	if (asset) {
		uint64_t offset = msg.offset();
		size_t size = msg.size();
		if (size > MAX_CHUNK)
			size = MAX_CHUNK;

		// Raw pointer to this should be fine here, since asset has ownership of this. (Through member Ptr client)
		auto onComplete = boost::bind(&Client::onReadResponse, this, msg, _1, _2, bithorde::Message::in(msg.timeout()));
		asset->async_read(offset, size, msg.timeout(), onComplete);
	} else {
		bithorde::Read::Response resp;
		resp.set_reqid(msg.reqid());
		resp.set_status(bithorde::INVALID_HANDLE);
		sendMessage(bithorde::Connection::ReadResponse, resp);
	}
}

void Client::onMessage(const bithorde::DataSegment& msg)
{
	const AssetBinding& asset_ = getAsset(msg.handle());
	if (asset_) {
		bithorded::cache::CachedAsset::Ptr asset = dynamic_pointer_cast<bithorded::cache::CachedAsset>(asset_.shared());
		if (asset) {
			asset->write(msg.offset(), msg.content());
		} else {
			LOG4CPLUS_ERROR(clientLogger, peerName() << ':' << msg.handle() << " is not an upload-asset");
		}
	} else {
		LOG4CPLUS_ERROR(clientLogger, peerName() << ':' << msg.handle() << " is not bound to any asset");
	}

	return;
}

void Client::setAuthenticated(const string peerName_)
{
	bithorde::Client::setAuthenticated(peerName_);
	if (peerName_.empty()) {
		LOG4CPLUS_WARN(clientLogger, peerName() << ": failed authentication");
		close();
	}
}

void Client::onReadResponse(const bithorde::Read::Request& req, int64_t offset, const std::string& data, bithorde::Message::Deadline t) {
	bithorde::Read::Response resp;
	resp.set_reqid(req.reqid());
	if ((offset >= 0) && (data.size() > 0)) {
		resp.set_status(bithorde::SUCCESS);
		resp.set_offset(offset);
		resp.set_content(data);
	} else {
		resp.set_status(bithorde::NOTFOUND);
	}
	if (!sendMessage(bithorde::Connection::ReadResponse, resp, t)) {
		LOG4CPLUS_WARN(clientLogger, "Failed to write data chunk, (offset " << offset << ')');
	}
}

void Client::informAssetStatus(bithorde::Asset::Handle h, bithorde::Status s)
{
	size_t asset_idx = h;
	if (asset_idx < _assets.size()) {
		_assets[asset_idx].clearDeadline();
	}

	bithorde::AssetStatus resp;
	resp.set_handle(h);
	resp.set_status(s);
	sendMessage(bithorde::Connection::AssetStatus, resp, bithorde::Message::NEVER, true);
}

void Client::informAssetStatusUpdate(bithorde::Asset::Handle h, const IAsset::WeakPtr& asset, const bithorde::AssetStatus& status)
{
	if (status.status() == bithorde::NONE)
		return;
	size_t asset_idx = h;
	if ((asset_idx >= _assets.size()) || (_assets[asset_idx] != asset.lock()))
		return;

	_assets[asset_idx].clearDeadline();
	bithorde::AssetStatus resp(status);
	resp.set_handle(h);

	LOG4CPLUS_DEBUG(clientLogger, peerName() << ':' << h << " new state " << bithorde::Status_Name(resp.status()) << " (" << resp.ids() << ")");

	sendMessage(bithorde::Connection::AssetStatus, resp);
}

void Client::assignAsset(bithorde::Asset::Handle handle_, const UpstreamRequestBinding::Ptr& a, const bithorde::RouteTrace& requesters, const boost::posix_time::ptime& deadline)
{
	size_t handle = handle_;
	if (handle >= _assets.size()) {
		if (handle >= MAX_ASSETS) {
			LOG4CPLUS_ERROR(clientLogger, peerName() << ": handle larger than allowed limit (" << handle << " > " << MAX_ASSETS << ")");
			informAssetStatus(handle_, bithorde::Status::INVALID_HANDLE);
			return;
		}
		size_t old_size = _assets.size();
		size_t new_size = _assets.size() + (handle - _assets.size() + 1) * 2;
		if (new_size > MAX_ASSETS)
			new_size = MAX_ASSETS;
		_assets.resize(new_size);
		auto self = shared_from_this();
		for (auto i=old_size; i < new_size; i++) {
			_assets[i].setClient(self);
		}
	}
	if (_assets[handle].bind(a, requesters, deadline)) {
		auto weak_asset = _assets[handle].weak();
		// Remember to inform peer about changes in asset-status.
		(*a)->status.onChange.connect(boost::bind(&Client::informAssetStatusUpdate, this, handle_, weak_asset, _2));

		if ((*a)->status->status() != bithorde::Status::NONE) {
			// We already have a valid status for the asset, so inform about it
			informAssetStatusUpdate(handle_, weak_asset, *((*a)->status));
		}
	} else {
		informAssetStatus(handle_, bithorde::Status::WOULD_LOOP);
	}
}

void Client::onDisconnected()
{
	clearAssets();
	bithorde::Client::onDisconnected();
}

void Client::clearAssets()
{
	for (size_t h=0; h < _assets.size(); h++)
		clearAsset(h);
	_assets.clear();
}

void Client::clearAsset(bithorde::Asset::Handle handle_)
{
	size_t handle = handle_;
	if (handle < _assets.size()) {
		if (auto& a=_assets[handle]) {
			a->status.onChange.disconnect(boost::bind(&Client::informAssetStatusUpdate, this, handle_, _assets[handle].weak(), _2));
			_assets[handle].reset();
			LOG4CPLUS_DEBUG(clientLogger, peerName() << ':' << handle_ << " released");
		}
	}
}

const AssetBinding& Client::getAsset(bithorde::Asset::Handle handle_) const
{
	size_t handle = handle_;
	if (handle < _assets.size())
		return _assets.at(handle);
	else
		return BINDING_NONE;
}
