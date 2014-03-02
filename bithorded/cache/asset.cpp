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
#include "manager.hpp"

#include <lib/buffer.hpp>
#include <bithorded/lib/grandcentraldispatch.hpp>

#include <log4cplus/logger.h>
#include <log4cplus/loggingmacros.h>

using namespace bithorded;
using namespace bithorded::cache;
using namespace bithorded::store;

namespace fs = boost::filesystem;

namespace bithorded { namespace cache {
	log4cplus::Logger assetLog = log4cplus::Logger::getInstance("cacheAsset");
} }

bithorded::cache::CachedAsset::CachedAsset(GrandCentralDispatch& gcd, const std::string& id, const store::HashStore::Ptr& hashStore, const IDataArray::Ptr& data) :
	StoredAsset(gcd, id, hashStore, data)
{
	auto trx = status.change();
	trx->set_status(hasRootHash() ? bithorde::SUCCESS : bithorde::NOTFOUND);
}

void bithorded::cache::CachedAsset::inspect(bithorded::management::InfoList& target) const
{
	target.append("type") << "Cached";
}

void CachedAsset::apply(const bithorded::AssetRequestParameters& old_parameters, const bithorded::AssetRequestParameters& new_parameters)
{}

ssize_t _write_held_buffer(const IDataArray::Ptr& storage, uint64_t offset, const boost::shared_ptr<bithorde::IBuffer>& data) {
	return storage->write(offset, **data, data->size());
}

// Dummy function used to hold the buffer in RAM until it's processed.
// Ensure we don't resume reading from client until all data is really processed
void whenDoneWrapper(const std::function< void() > whenDone, const boost::shared_ptr<bithorde::IBuffer>& dataHolder) {
	whenDone();
}

void bithorded::cache::CachedAsset::write(uint64_t offset, const boost::shared_ptr<bithorde::IBuffer>& data, const std::function< void() > whenDone )
{
	auto job = boost::bind(&_write_held_buffer, _data, offset, data);
	boost::function< void() > wrappedDone = boost::bind(&whenDoneWrapper, whenDone, data);
	auto completion = boost::bind(&StoredAsset::notifyValidRange, shared_from_this(), offset, _1, whenDone);
	_gcd.submit(job, completion);
}

CachedAsset::Ptr CachedAsset::open(GrandCentralDispatch& gcd, const boost::filesystem::path& path ) {
	AssetMeta meta;

	switch (fs::status(path).type()) {
	case boost::filesystem::directory_file:
		meta = store::openV1AssetMeta(path/"meta");
		meta.tail = boost::make_shared<RandomAccessFile>(path/"data");
		break;
	case boost::filesystem::regular_file:
		meta = store::openV2AssetMeta(path);
		break;
	case boost::filesystem::file_not_found:
		return CachedAsset::Ptr();
	default:
		LOG4CPLUS_WARN(assetLog, "Asset of unknown type: " << path);
		return CachedAsset::Ptr();
	}

	return boost::make_shared<CachedAsset>(gcd, path.filename().native(), meta.hashStore, meta.tail);
}

CachedAsset::Ptr CachedAsset::create( GrandCentralDispatch& gcd, const boost::filesystem::path& path, uint64_t size ) {
	auto meta = store::createAssetMeta(path, store::V2CACHE, size, store::DEFAULT_HASH_LEVELS_SKIPPED, size);

	auto ptr = boost::make_shared<CachedAsset>(gcd, path.filename().native(), meta.hashStore, meta.tail);
	ptr->status.change()->set_status(bithorde::SUCCESS);
	return ptr;
}

bithorded::cache::CachingAsset::CachingAsset( CacheManager& mgr, const IAsset::Ptr& upstream, const CachedAsset::Ptr& cached ) :
	_manager(mgr),
	_upstream(upstream),
	_upstreamTracker(_upstream->status.onChange.connect(boost::bind(&CachingAsset::upstreamStatusChange, this, _2))),
	_cached(cached),
	_delayedCreation(false)
{
	status = *_upstream->status;
}

bithorded::cache::CachingAsset::~CachingAsset()
{
	disconnect();
}

void bithorded::cache::CachingAsset::inspect(bithorded::management::InfoList& target) const
{
	target.append("type") << "caching";
	if (_upstream)
		_upstream->inspect(target);
}

void bithorded::cache::CachingAsset::async_read(uint64_t offset, size_t size, uint32_t timeout, bithorded::IAsset::ReadCallback cb)
{
	auto cached_ = cached();
	if (cached_ && (cached_->can_read(offset, size) == size)) {
		cached_->async_read(offset, size, timeout, cb);
	} else if (_upstream) {
		_upstream->async_read(offset, size, timeout, boost::bind(&CachingAsset::upstreamDataArrived, shared_from_this(), cb, size, _1, _2));
	} else {
		cb(-1, bithorde::NullBuffer::instance);
	}
}

size_t bithorded::cache::CachingAsset::can_read(uint64_t offset, size_t size)
{
	if (_upstream)
		return _upstream->can_read(offset, size);
	else if (auto cached_ = cached())
		return (cached_->can_read(offset, size) == size) ? size : 0;
	else
		return 0;
}

uint64_t bithorded::cache::CachingAsset::size()
{
	if (auto cached_ = cached())
		return cached_->size();
	else if (_upstream)
		return _upstream->size();
	else
		return 0;
}

void CachingAsset::apply(const bithorded::AssetRequestParameters& old_parameters, const bithorded::AssetRequestParameters& new_parameters)
{
	if (_upstream)
		_upstream->apply(old_parameters, new_parameters);
}

void bithorded::cache::CachingAsset::disconnect()
{
	_upstreamTracker.disconnect();
	_upstream.reset();
}

void bithorded::cache::CachingAsset::upstreamDataArrived( IAsset::ReadCallback cb, std::size_t requested_size, int64_t offset, const boost::shared_ptr< bithorde::IBuffer >& data )
{
	auto cached_ = cached();
	if (data->size() >= requested_size) {
		if (cached_) {
			cached_->write(offset, data, boost::bind(&CachingAsset::releaseIfCached, shared_from_this()));
		}
		cb(offset, data);
	} else if (cached_ && (cached_->can_read(offset, requested_size) == requested_size)) {
		cached_->async_read(offset, requested_size, 0, cb);
	} else {
		cb(offset, data);
	}
}

void bithorded::cache::CachingAsset::upstreamStatusChange(const bithorde::AssetStatus& newStatus)
{
	if ((newStatus.status() == bithorde::Status::SUCCESS) && !_cached && _upstream->size() > 0) {
		_delayedCreation = true;
	}
	if (_cached && _cached->hasRootHash()) {
		status = *_cached->status;
	} else {
		status = newStatus;
	}
}

void CachingAsset::releaseIfCached()
{
	auto cached_ = cached();
	if (cached_ && cached_->hasRootHash())
		disconnect();
}

bithorded::cache::CachedAsset::Ptr bithorded::cache::CachingAsset::cached()
{
	if (_delayedCreation && _upstream) {
		_delayedCreation = false;
		_cached = _manager.prepareUpload(_upstream->size(), _upstream->status->ids());
	}
	return _cached;
}
