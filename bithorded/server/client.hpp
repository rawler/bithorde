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

#include "lib/allocator.h"
#include "lib/client.h"
#include "asset.hpp"

namespace bithorded {

class Server;
class Client : public bithorde::Client, public boost::enable_shared_from_this<Client>
{
	Server& _server;
	std::vector< Asset::Ptr > _assets;
public:
	typedef boost::shared_ptr<Client> Ptr;
	typedef boost::weak_ptr<Client> WeakPtr;
	static Ptr create(Server& server) {
		return Ptr(new Client(server));
	}
	bool requestsAsset(const BitHordeIds& ids);

protected:
	Client(Server& server);

	virtual void onMessage(const bithorde::HandShake& msg);
	virtual void onMessage(const bithorde::BindWrite& msg);
	virtual void onMessage(bithorde::BindRead& msg);
	virtual void onMessage(const bithorde::Read::Request& msg);

private:
	void informAssetStatus(bithorde::Asset::Handle h, bithorde::Status s);
	void informAssetStatusUpdate(bithorde::Asset::Handle h, const bithorded::Asset::WeakPtr& asset);
	void onReadResponse( const bithorde::Read::Request& req, int64_t offset, const std::string& data);
	void onLinkHashDone(bithorde::Asset::Handle handle, bithorded::Asset::Ptr a);
	bool assignAsset(bithorde::Asset::Handle handle, const bithorded::Asset::Ptr& a);
	void clearAsset(bithorde::Asset::Handle handle);
	Asset::Ptr& getAsset(bithorde::Asset::Handle handle);
};

}
#endif // BITHORDED_CLIENT_H
