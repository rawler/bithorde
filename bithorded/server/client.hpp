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


#ifndef BITHORDED_CLIENT_H
#define BITHORDED_CLIENT_H

#include <boost/smart_ptr/enable_shared_from_this.hpp>

#include "../lib/management.hpp"
#include "lib/allocator.h"
#include "lib/client.h"
#include "asset.hpp"

namespace bithorded {

class Server;
class Client : public bithorde::Client, public management::DescriptiveDirectory
{
	Server& _server;
	std::vector< AssetBinding > _assets;
public:
	typedef boost::shared_ptr<Client> Ptr;
	typedef boost::weak_ptr<Client> WeakPtr;
	static Ptr create(Server& server) {
		return Ptr(new Client(server));
	}

	Ptr shared_from_this();

	size_t serverAssets() const;

	virtual void describe(management::Info& target) const;
	virtual void inspect(management::InfoList& target) const;

	~Client() { clearAssets(); }

protected:
	Client(Server& server);

	virtual void onDisconnected();

	virtual void onMessage(const boost::shared_ptr<bithorde::MessageContext<bithorde::HandShake> >& msgCtx);
	virtual void onMessage(const boost::shared_ptr<bithorde::MessageContext<bithorde::BindWrite> >& msgCtx);
	virtual void onMessage(const boost::shared_ptr<bithorde::MessageContext<bithorde::BindRead> >& msgCtx);
	virtual void onMessage(const boost::shared_ptr<bithorde::MessageContext<bithorde::Read::Request> >& msgCtx);
	virtual void onMessage(const boost::shared_ptr<bithorde::MessageContext<bithorde::DataSegment> >& msgCtx);

	virtual void setAuthenticated(const std::string peerName);
private:
	void informAssetStatus(bithorde::Asset::Handle h, bithorde::Status s);
	void informAssetStatusUpdate(bithorde::Asset::Handle h, const bithorded::IAsset::WeakPtr& asset, const bithorde::AssetStatus& status);
	void onReadResponse( const boost::shared_ptr< bithorde::MessageContext< bithorde::Read::Request > >& reqCtx, int64_t offset, const boost::shared_ptr< bithorde::IBuffer >& data, bithorde::Message::Deadline t );
	void assignAsset( bithorde::Asset::Handle handle_, const bithorded::UpstreamRequestBinding::Ptr& a, const BitHordeIds& assetIds, const bithorde::RouteTrace& requesters, const boost::posix_time::ptime& deadline );
	void clearAssets();
	void clearAsset(bithorde::Asset::Handle handle);
	const AssetBinding& getAsset(bithorde::Asset::Handle handle_) const;
};

static AssetBinding BINDING_NONE;

}
#endif // BITHORDED_CLIENT_H
