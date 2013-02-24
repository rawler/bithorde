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

bool Client::requestsAsset(const BitHordeIds& ids) {
	for (auto iter=_assets.begin(); iter!=_assets.end(); iter++) {
		auto asset = *iter;
		if (asset) {
			BitHordeIds assetIds;
			if (asset->getIds(assetIds) && idsOverlap(assetIds, ids))
				return true;
		}
	}
	return false;
}

void Client::onMessage(const bithorde::HandShake& msg)
{
	bithorde::Client::onMessage(msg);
	LOG4CPLUS_INFO(clientLogger, "Connected: " << msg.name());
}

void Client::onMessage(const bithorde::BindWrite& msg)
{
	if (msg.has_linkpath()) {
		fs::path path(msg.linkpath());
		if (path.is_absolute()) {
			if (auto asset = _server.async_linkAsset(path)) {
				LOG4CPLUS_INFO(clientLogger, "Linking " << path);
				assignAsset(msg.handle(), asset);
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
			assignAsset(msg.handle(), asset);
		} else {
			informAssetStatus(msg.handle(), bithorde::NORESOURCES);
		}
	}
}

void Client::onMessage(bithorde::BindRead& msg)
{
	bithorde::Asset::Handle h = msg.handle();
	if (((int)_assets.size() > h) && _assets[h]) {
		clearAsset(h);
	}
	if (msg.ids_size() > 0) {
		// Trying to open
		LOG4CPLUS_INFO(clientLogger, peerName() << ':' << h << " requested: " << MagnetURI(msg));
		if (!msg.has_uuid())
			msg.set_uuid(rand64());

		try {
			auto asset = _server.async_findAsset(msg);
			if (asset)
				assignAsset(h, asset);
			else
				informAssetStatus(h, bithorde::NOTFOUND);
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
	IAsset::Ptr& asset = getAsset(msg.handle());
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
	IAsset::Ptr& asset_ = getAsset(msg.handle());
	if (asset_) {
		bithorded::cache::CachedAsset::Ptr asset = dynamic_pointer_cast<bithorded::cache::CachedAsset>(asset_);
		if (asset) {
			asset->write(msg.offset(), msg.content());
		} else {
			LOG4CPLUS_INFO(clientLogger, peerName() << ':' << msg.handle() << " is not an upload-asset");
		}
	} else {
		LOG4CPLUS_INFO(clientLogger, peerName() << ':' << msg.handle() << " is not bound to any asset");
	}

	return;
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
	bithorde::AssetStatus resp;
	resp.set_handle(h);
	resp.set_status(s);
	sendMessage(bithorde::Connection::AssetStatus, resp);
}

void Client::informAssetStatusUpdate(bithorde::Asset::Handle h, const bithorded::IAsset::WeakPtr& asset_)
{
	bithorde::AssetStatus resp;
	resp.set_handle(h);

	if (auto asset = asset_.lock()) {
		if (asset->status == bithorde::NONE)
			return;
		resp.set_status(asset->status);
		if (asset->status == bithorde::SUCCESS) {
			resp.set_availability(1000);
			resp.set_size(asset->size());
			asset->getIds(*resp.mutable_ids());
		}
	} else {
		resp.set_status(bithorde::NOTFOUND);
	}
	LOG4CPLUS_INFO(clientLogger, peerName() << ':' << h << " new state " << bithorde::Status_Name(resp.status()));

	sendMessage(bithorde::Connection::AssetStatus, resp);
}

bithorde::Status Client::assignAsset(bithorde::Asset::Handle handle_, const IAsset::Ptr& a)
{
	size_t handle = handle_;
	if (handle >= _assets.size()) {
		if (handle >= MAX_ASSETS) {
			LOG4CPLUS_ERROR(clientLogger, peerName() << ": handle larger than allowed limit (" << handle << " < " << MAX_ASSETS << ")");
			return bithorde::INVALID_HANDLE;
		}
		size_t new_size = _assets.size() + (handle - _assets.size() + 1) * 2;
		if (new_size > MAX_ASSETS)
			new_size = MAX_ASSETS;
		_assets.resize(new_size);
	}
	_assets[handle] = a;

	// Remember to inform peer about changes in asset-status.
	a->statusChange.connect(boost::bind(&Client::informAssetStatusUpdate, this, handle_, IAsset::WeakPtr(a)));

	if (a->status != bithorde::Status::NONE) {
		// We already have a valid status for the asset, so inform about it
		informAssetStatusUpdate(handle_, a);
	}

	return a->status;
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
			a->statusChange.disconnect(boost::bind(&Client::informAssetStatusUpdate, this, handle_, IAsset::WeakPtr(a)));
			_assets[handle].reset();
		}
	}
	LOG4CPLUS_INFO(clientLogger, peerName() << ':' << handle_ << " released");
}

IAsset::Ptr& Client::getAsset(bithorde::Asset::Handle handle_)
{
	size_t handle = handle_;
	if (handle < _assets.size())
		return _assets.at(handle);
	else
		return ASSET_NONE;
}
