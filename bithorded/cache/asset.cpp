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

bithorded::cache::CachedAsset::CachedAsset(GrandCentralDispatch& gcd, const boost::filesystem::path& metaFolder) :
	StoredAsset(gcd, metaFolder, RandomAccessFile::READWRITE)
{
	setStatus(hasRootHash() ? bithorde::SUCCESS : bithorde::NOTFOUND);
}

bithorded::cache::CachedAsset::CachedAsset(GrandCentralDispatch& gcd, const boost::filesystem::path& metaFolder, uint64_t size) :
	StoredAsset(gcd, metaFolder, RandomAccessFile::READWRITE, size)
{
	setStatus(bithorde::SUCCESS);
}

void bithorded::cache::CachedAsset::inspect(bithorded::management::InfoList& target) const
{
	target.append("type") << "Cached";
}

size_t bithorded::cache::CachedAsset::write(uint64_t offset, const std::string& data)
{
	auto res = _file.write(offset, data.data(), data.length());
	notifyValidRange(offset, data.length());
	updateStatus();
	return res;
}

bithorded::cache::CachingAsset::CachingAsset(bithorded::cache::CacheManager& mgr, bithorded::router::ForwardedAsset::Ptr upstream, bithorded::cache::CachedAsset::Ptr cached)
	: _manager(mgr), _upstream(upstream), _cached(cached), _delayedCreation(false)
{
	if (_upstream)
		setStatus(_upstream->status);
	_upstream->statusChange.connect(boost::bind(&CachingAsset::upstreamStatusChange, this, _1));
}

bithorded::cache::CachingAsset::~CachingAsset()
{
	disconnect();
}

void bithorded::cache::CachingAsset::inspect(bithorded::management::InfoList& target) const
{
	target.append("type") << "caching";
	if (_upstream)
		_upstream->inspect_upstreams(target);
}

void bithorded::cache::CachingAsset::async_read(uint64_t offset, size_t& size, uint32_t timeout, bithorded::IAsset::ReadCallback cb)
{
	size_t trimmed_size;
	auto cached_ = cached();
	if (cached_ && (trimmed_size = cached_->can_read(offset, size))) {
		cached_->async_read(offset, trimmed_size, timeout, cb);
	} else if (_upstream) {
		_upstream->async_read(offset, size, timeout, boost::bind(&CachingAsset::upstreamDataArrived, shared_from_this(), cb, _1, _2));
	} else {
		cb(-1, "");
	}
}

bool bithorded::cache::CachingAsset::getIds(BitHordeIds& ids) const
{
	if (_upstream)
		return _upstream->getIds(ids);
	else if (_cached)
		return _cached->getIds(ids);
	else
		return false;
}

size_t bithorded::cache::CachingAsset::can_read(uint64_t offset, size_t size)
{
	if (_upstream)
		return _upstream->can_read(offset, size);
	else if (auto cached_ = cached())
		return cached_->can_read(offset, size);
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

void bithorded::cache::CachingAsset::disconnect()
{
	if (_upstream)
		_upstream->statusChange.disconnect(boost::bind(&CachingAsset::upstreamStatusChange, this));
	_upstream.reset();
}

void bithorded::cache::CachingAsset::upstreamDataArrived(bithorded::IAsset::ReadCallback cb, int64_t offset, const std::string& data)
{
	cb(offset, data);
	if (auto cached_ = cached()) {
		cached_->write(offset, data);
		if (cached_->hasRootHash())
			disconnect();
	}
}

void bithorded::cache::CachingAsset::upstreamStatusChange(bithorde::Status newStatus)
{
	if ((newStatus == bithorde::Status::SUCCESS) && !_cached && _upstream->size() > 0) {
		_delayedCreation = true;
	}
	if (_cached && _cached->hasRootHash())
		newStatus = bithorde::Status::SUCCESS;
	setStatus(newStatus);
}

bithorded::cache::CachedAsset::Ptr bithorded::cache::CachingAsset::cached()
{
	if (_delayedCreation && _upstream) {
		BitHordeIds ids;
		_delayedCreation = false;
		_upstream->getIds(ids);
		_cached = _manager.prepareUpload(_upstream->size(), ids);
	}
	return _cached;
}
