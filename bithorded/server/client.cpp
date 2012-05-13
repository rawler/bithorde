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

#include <glog/logging.h>

#include "server.hpp"
#include "../../lib/magneturi.h"
#include "../../lib/random.h"

const size_t MAX_ASSETS = 1024;
const size_t MAX_CHUNK = 64*1024;

using namespace std;
namespace fs = boost::filesystem;

using namespace bithorded;

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
	LOG(INFO) << "Connected: " << msg.name() << endl;
}

void Client::onMessage(const bithorde::BindWrite& msg)
{
	bithorde::Asset::Handle h = msg.handle();
	bithorde::AssetStatus resp;
	resp.set_handle(h);
	if (msg.has_linkpath()) {
		fs::path path(msg.linkpath());
		if (path.is_absolute()) {
			if (_server.linkAsset(path, boost::bind(&Client::onLinkHashDone, shared_from_this(), h, _1))) {
				LOG(INFO) << "Hashing " << path << endl;
				resp.set_status(bithorde::SUCCESS);
			} else {
				LOG(ERROR) << "Upload did not match any allowed assetStore: " << path << endl;
				resp.set_status(bithorde::ERROR);
			}
		}
	} else {
		LOG(ERROR) << "Sorry, upload isn't supported yet" << endl;
		resp.set_status(bithorde::ERROR);
	}
	sendMessage(bithorde::Connection::AssetStatus, resp);
}

void Client::onMessage(bithorde::BindRead& msg)
{
	bithorde::Asset::Handle h = msg.handle();
	if (msg.ids_size() > 0) {
		// Trying to open
		LOG(INFO) << peerName() << ':' << h << " requested: " << MagnetURI(msg) << endl;
		if (!msg.has_uuid())
			msg.set_uuid(rand64());

		try {
			auto asset = _server.async_findAsset(msg);
			if (!asset)
				return informAssetStatus(h, bithorde::NOTFOUND);
			if (!assignAsset(h, asset))
				return informAssetStatus(h, bithorde::INVALID_HANDLE);

			// Remember to inform peer about changes in asset-status.
			asset->statusChange.connect(boost::bind(&Client::informAssetStatusUpdate, this, h, Asset::WeakPtr(asset)));

			if (asset->status != bithorde::Status::NONE) {
				// We already have a valid status for the asset, so inform about it
				informAssetStatusUpdate(h, asset);
			}
		} catch (bithorded::BindError e) {
			informAssetStatus(h, e.status);
		}
	} else {
		// Trying to close
		LOG(INFO) << peerName() << ':' << h << " closed" << endl;
		clearAsset(h);
		informAssetStatus(h, bithorde::NOTFOUND);
	}
}

void Client::onMessage(const bithorde::Read::Request& msg)
{
	Asset::Ptr& asset = getAsset(msg.handle());
	if (asset) {
		uint64_t offset = msg.offset();
		size_t size = msg.size();
		if (size > MAX_CHUNK)
			size = MAX_CHUNK;

		// Raw pointer to this should be fine here, since asset has ownership of this. (Through member Ptr client)
		asset->async_read(offset, size, boost::bind(&Client::onReadResponse, this, msg, _1, _2));
	} else {
		bithorde::Read::Response resp;
		resp.set_reqid(msg.reqid());
		resp.set_status(bithorde::INVALID_HANDLE);
		sendMessage(bithorde::Connection::ReadResponse, resp);
	}
}

void Client::onReadResponse(const bithorde::Read::Request& req, int64_t offset, const std::string& data) {
	bithorde::Read::Response resp;
	resp.set_reqid(req.reqid());
	if ((offset >= 0) && (data.size() > 0)) {
		resp.set_status(bithorde::SUCCESS);
		resp.set_offset(offset);
		resp.set_content(data);
	} else {
		resp.set_status(bithorde::NOTFOUND);
	}
	sendMessage(bithorde::Connection::ReadResponse, resp);
}

void Client::informAssetStatus(bithorde::Asset::Handle h, bithorde::Status s)
{
	bithorde::AssetStatus resp;
	resp.set_handle(h);
	resp.set_status(s);
	sendMessage(bithorde::Connection::AssetStatus, resp);
}

void Client::informAssetStatusUpdate(bithorde::Asset::Handle h, const bithorded::Asset::WeakPtr& asset_)
{
	bithorde::AssetStatus resp;
	resp.set_handle(h);

	if (auto asset = asset_.lock()) {
		resp.set_status(asset->status);
		if (asset->status == bithorde::SUCCESS) {
			resp.set_availability(1000);
			resp.set_size(asset->size());
			asset->getIds(*resp.mutable_ids());
		}
	} else {
		resp.set_status(bithorde::NOTFOUND);
	}
	LOG(INFO) << peerName() << ':' << h << " new state " << bithorde::Status_Name(resp.status()) << endl;

	sendMessage(bithorde::Connection::AssetStatus, resp);
}

void Client::onLinkHashDone(bithorde::Asset::Handle handle, Asset::Ptr a)
{
	bithorde::AssetStatus resp;
	resp.set_handle(handle);
	if (a && a->getIds(*resp.mutable_ids())) {
		resp.set_status(bithorde::SUCCESS);
		resp.set_size(a->size());
	} else {
		resp.set_status(bithorde::ERROR);
	}
	
	sendMessage(bithorde::Connection::AssetStatus, resp);
}

bool Client::assignAsset(bithorde::Asset::Handle handle_, const Asset::Ptr& a)
{
	size_t handle = handle_;
	if (handle >= _assets.size()) {
		if (handle > MAX_ASSETS) {
			LOG(ERROR) << peerName() << ": handle larger than allowed limit (" << handle << " < " << MAX_ASSETS << ")" << endl;
			return false;
		}
		size_t new_size = _assets.size() + (handle - _assets.size() + 1) * 2;
		if (new_size > MAX_ASSETS)
			new_size = MAX_ASSETS;
		_assets.resize(new_size);
	}
	_assets[handle] = a;
	return true;
}

void Client::clearAsset(bithorde::Asset::Handle handle_)
{
	size_t handle = handle_;
	if (handle < _assets.size())
		_assets[handle].reset();
}

Asset::Ptr& Client::getAsset(bithorde::Asset::Handle handle_)
{
	size_t handle = handle_;
	if (handle < _assets.size())
		return _assets.at(handle);
	else
		return ASSET_NONE;
}
