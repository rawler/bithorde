/*
    Copyright 2016 Ulrik Mikaelsson <ulrik.mikaelsson@gmail.com>

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
#include "server.hpp"

#include <iostream>

#include <bithorded/lib/log.hpp>
#include <lib/buffer.hpp>
#include <lib/hashes.h>
#include <lib/magneturi.h>
#include <lib/random.h>

const size_t MAX_ASSETS = 1024;
const size_t MAX_CHUNK = 128*1024;

using namespace std;
namespace fs = boost::filesystem;

using namespace bithorded;

namespace bithorded {
	Logger clientLogger;
}

Client::Client( Server& server) :
	bithorde::Client(server.ioCtx(), server.name()),
	_server(server)
{
}

Client::Ptr Client::shared_from_this() {
	return std::static_pointer_cast<Client>(bithorde::Client::shared_from_this());
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
	tgt.append("bytesAllocated") << bytesAllocated();
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

void Client::onMessage( const std::shared_ptr< bithorde::MessageContext< bithorde::HandShake > >& msgCtx )
{
	const auto& msg = msgCtx->message();
	if (!(state() & SaidHello)) {
		auto client_config = _server.getClientConfig( msg.name());
		setSecurity(client_config.key, (bithorde::CipherType)client_config.cipher);
		sayHello();
	}
	BOOST_LOG_SEV(clientLogger, bithorded::info) << "Connected: " << msg.name();
	bithorde::Client::onMessage( msgCtx );
}

void Client::onMessage( const std::shared_ptr< bithorde::MessageContext< bithorde::BindWrite > >& msgCtx )
{
	const auto& msg = msgCtx->message();
	auto h = msg.handle();
	if ((_assets.size() > h) && _assets[h]) {
		clearAsset(h);
	}
	if ( msg.has_linkpath()) {
		fs::path path( msg.linkpath());
		if (path.is_absolute()) {
			if (auto asset = _server.asyncLinkAsset(path)) {
				BOOST_LOG_SEV(clientLogger, bithorded::info) << "Linking " << path;
				assignAsset( msg.handle(), asset, bithorde::Ids(), bithorde::RouteTrace(), boost::posix_time::neg_infin);
			} else {
				BOOST_LOG_SEV(clientLogger, bithorded::error) << "Upload did not match any allowed assetStore: " << path;
				informAssetStatus( msg.handle(), bithorde::ERROR);
			}
		} else {
			BOOST_LOG_SEV(clientLogger, bithorded::error) << "Relative links not supported" << path;
			informAssetStatus( msg.handle(), bithorde::ERROR);
		}
	} else {
		if (auto asset = _server.prepareUpload( msg.size())) {
			BOOST_LOG_SEV(clientLogger, bithorded::info) << "Ready for upload of size " << msg.size();
			assignAsset( msg.handle(), asset, bithorde::Ids(), bithorde::RouteTrace(), boost::posix_time::neg_infin);
		} else {
			informAssetStatus( msg.handle(), bithorde::NORESOURCES);
		}
	}
}

void Client::onMessage( const std::shared_ptr< bithorde::MessageContext< bithorde::BindRead > >& msgCtx )
{
	const auto& msg = msgCtx->message();
	auto h = msg.handle();

	if (msg.ids_size() > 0) {
		// Trying to open
		BOOST_LOG_SEV(clientLogger, bithorded::debug) << peerName() << ':' << h << " requested: " << MagnetURI(msg);
	}

	if ((_assets.size() > h) && _assets[h]) {
		auto& asset = _assets[h];
		if (idsOverlap(asset->status->ids(), msg.ids())) {
			if (asset.bind(msg.requesters())) {
				informAssetStatusUpdate(h, asset.shared(), *(asset->status));
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
			auto asset = _server.asyncFindAsset(msg);
			if (asset) {
				boost::posix_time::ptime deadline(boost::posix_time::neg_infin);
				if (msg.has_timeout()) {
					auto now = boost::posix_time::microsec_clock::universal_time();
					deadline = now + boost::posix_time::milliseconds(msg.timeout());
				}
				assignAsset(h, asset, msg.ids(), msg.requesters(), deadline);
			} else {
				informAssetStatus(h, bithorde::NOTFOUND);
			}
		} catch (bithorded::BindError& e) {
			informAssetStatus(h, e.status);
		}
	} else {
		// Trying to close
		informAssetStatus(h, bithorde::NOTFOUND);
	}
}

void Client::onMessage( const std::shared_ptr< bithorde::MessageContext< bithorde::Read::Request > >& msgCtx )
{
	const auto& msg = msgCtx->message();
	const AssetBinding& asset = getAsset(msg.handle());
	if (asset) {
		uint64_t offset = msg.offset();
		size_t size = msg.size();
		if (size > MAX_CHUNK)
			size = MAX_CHUNK;

		if (offset < asset->size()) {
			// Raw pointer to this should be fine here, since asset has ownership of this. (Through member Ptr client)
			auto deadline = bithorde::Message::in(msg.timeout());
			asset->asyncRead(offset, size, msg.timeout(),
				std::bind(&Client::onReadResponse, this, msgCtx, std::placeholders::_1, std::placeholders::_2, deadline));
		} else {
			bithorde::Read::Response resp;
			resp.set_reqid(msg.reqid());
			resp.set_status(bithorde::ERROR);
			sendMessage(bithorde::Connection::ReadResponse, resp);
		}
	} else {
		bithorde::Read::Response resp;
		resp.set_reqid(msg.reqid());
		resp.set_status(bithorde::INVALID_HANDLE);
		sendMessage(bithorde::Connection::ReadResponse, resp);
	}
}

void Client::onMessage( const std::shared_ptr< bithorde::MessageContext< bithorde::DataSegment > >& msgCtx )
{
	const auto& msg = msgCtx->message();
	const AssetBinding& asset_ = getAsset(msg.handle());

	if (asset_) {
		bithorded::cache::CachedAsset::Ptr asset = dynamic_pointer_cast<bithorded::cache::CachedAsset>(asset_.shared());
		if (asset) {
			asset->write(msg.offset(), std::make_shared<bithorde::DataSegmentCtxBuffer>(msgCtx));
		} else {
			BOOST_LOG_SEV(clientLogger, bithorded::error) << peerName() << ':' << msg.handle() << " is not an upload-asset";
		}
	} else {
		BOOST_LOG_SEV(clientLogger, bithorded::error) << peerName() << ':' << msg.handle() << " is not bound to any asset";
	}

	return;
}

void Client::setAuthenticated(const string peerName_)
{
	bithorde::Client::setAuthenticated(peerName_);
	if (peerName_.empty()) {
		BOOST_LOG_SEV(clientLogger, bithorded::warning) << peerName() << ": failed authentication";
		close();
	}
}

void Client::onReadResponse(const std::shared_ptr< bithorde::MessageContext<bithorde::Read::Request> >& reqCtx, int64_t offset, const std::shared_ptr<bithorde::IBuffer>& data, bithorde::Message::Deadline t) {
	bithorde::Read::Response resp;
	resp.set_reqid( reqCtx->message().reqid());
	auto size = data->size();
	if ((offset >= 0) && (size > 0)) {
		resp.set_status(bithorde::SUCCESS);
		resp.set_offset(offset);
		resp.set_content(**data, size);
	} else {
		resp.set_status(bithorde::NOTFOUND);
	}
	if (!sendMessage(bithorde::Connection::ReadResponse, resp, t)) {
		BOOST_LOG_SEV(clientLogger, bithorded::warning) << "Failed to write data chunk, (offset " << offset << ')';
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

void Client::informAssetStatusUpdate(bithorde::Asset::Handle h, const IAsset::Ptr& asset, const bithorde::AssetStatus& status)
{
	if (status.status() == bithorde::NONE)
		return;
	size_t asset_idx = h;
	if ((asset_idx >= _assets.size()) || (_assets[asset_idx] != asset))
		return;
	_assets[asset_idx].clearDeadline();
	bithorde::AssetStatus resp(status);
	resp.set_handle(h);
	if ((resp.status() == bithorde::SUCCESS)
			&& _assets[asset_idx].assetIds().size()
			&& !idsOverlap(_assets[asset_idx].assetIds(), status.ids())
			) {
		BOOST_LOG_SEV(clientLogger, bithorded::warning) << peerName() << ':' << h << " new state with mismatching asset ids (" << idsToString(resp.ids()) << ")";
		resp.set_status(bithorde::NOTFOUND);
	}
	if (status.size() > (static_cast<uint64_t>(1)<<60)) {
		BOOST_LOG_SEV(clientLogger, bithorded::warning) << peerName() << ':' << h << " new state with suspiciously large size" << resp.size() << ", " << status.has_size();
	}

	BOOST_LOG_SEV(clientLogger, bithorded::debug) << peerName() << ':' << h << " new state " << bithorde::Status_Name(resp.status()) << " (" << idsToString(resp.ids()) << ") availability: " << resp.availability();

	sendMessage(bithorde::Connection::AssetStatus, resp, bithorde::Message::NEVER, true);
}

void Client::assignAsset(bithorde::Asset::Handle handle_, const UpstreamRequestBinding::Ptr& a, const bithorde::Ids& assetIds, const bithorde::RouteTrace& requesters, const boost::posix_time::ptime& deadline)
{
	size_t handle = handle_;
	if (handle >= _assets.size()) {
		if (handle >= MAX_ASSETS) {
			BOOST_LOG_SEV(clientLogger, bithorded::error) << peerName() << ": handle larger than allowed limit (" << handle << " > " << MAX_ASSETS << ")";
			informAssetStatus(handle_, bithorde::Status::INVALID_HANDLE);
			return;
		}
		size_t old_size = _assets.size();
		size_t new_size = _assets.size() + (handle - _assets.size() + 1) * 2;
		if (new_size > MAX_ASSETS)
			new_size = MAX_ASSETS;
		_assets.resize(new_size);
		auto self = bithorded::Client::shared_from_this();
		for (auto i=old_size; i < new_size; i++) {
			_assets[i].setClient(self);
		}
	}

	auto statusUpdate = std::bind (&Client::informAssetStatusUpdate, this,
		handle_, std::placeholders::_1, std::placeholders::_2);
	if (!_assets[handle].bind(a, assetIds, requesters, deadline, statusUpdate)) {
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
		if ( auto& a = _assets[handle] ) {
			a.reset();
			BOOST_LOG_SEV(clientLogger, bithorded::debug) << peerName() << ':' << handle_ << " released";
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
