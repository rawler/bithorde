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

bithorded::cache::CachedAsset::CachedAsset(const boost::filesystem::path& metaFolder) :
	StoredAsset(metaFolder)
{
	setStatus(hasRootHash() ? bithorde::SUCCESS : bithorde::NOTFOUND);
}

bithorded::cache::CachedAsset::CachedAsset(const boost::filesystem::path& metaFolder, uint64_t size) :
	StoredAsset(metaFolder, size)
{
	setStatus(bithorde::SUCCESS);
}

void bithorded::cache::CachedAsset::inspect(bithorded::management::InfoList& target) const
{
	target.append("type") << "Cached";
}

size_t bithorded::cache::CachedAsset::write(uint64_t offset, const std::string& data)
{
	_file.write(offset, data.data(), data.length());
	notifyValidRange(offset, data.length());
	updateStatus();
	return 0;
}

bithorded::cache::CachingAsset::CachingAsset(bithorded::cache::CacheManager& mgr, bithorded::router::ForwardedAsset::Ptr upstream, bithorded::cache::CachedAsset::Ptr cached)
	: _manager(mgr), _upstream(upstream), _cached(cached)
{
	_upstream->statusChange.connect(boost::bind(&CachingAsset::upstreamStatusChange, this, _1));
}

bithorded::cache::CachingAsset::~CachingAsset()
{
	disconnect();
}

void bithorded::cache::CachingAsset::inspect(bithorded::management::InfoList& target) const
{
	target.append("type") << "caching";
	target.append("upstream", _upstream.get());
}

void bithorded::cache::CachingAsset::async_read(uint64_t offset, size_t& size, uint32_t timeout, bithorded::IAsset::ReadCallback cb)
{
	if (_cached && _cached->can_read(offset, size)) {
		_cached->async_read(offset, size, timeout, cb);
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
	else if (_cached)
		return _cached->can_read(offset, size);
	else
		return 0;
}

uint64_t bithorded::cache::CachingAsset::size()
{
	if (_cached)
		return _cached->size();
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
	if (_cached) {
		_cached->write(offset, data);
		if (_cached->hasRootHash())
			disconnect();
	}
}

void bithorded::cache::CachingAsset::upstreamStatusChange(bithorde::Status newStatus)
{
	if ((newStatus == bithorde::Status::SUCCESS) && !_cached && _upstream->size() > 0)
		_cached = _manager.prepareUpload(_upstream->size());
	bool statusOk = (newStatus == bithorde::Status::SUCCESS) || (_cached && _cached->hasRootHash());
	setStatus(statusOk ? bithorde::Status::SUCCESS : bithorde::Status::NOTFOUND);
}
