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


#include "client.hpp"

#include <iostream>

#include "server.hpp"
#include "lib/magneturi.h"

using namespace std;
namespace fs = boost::filesystem;

using namespace bithorded;

Client::Client(Server& server, string myName) :
	bithorde::Client(server.ioService(), myName), 
	_server(server)
{
}

void Client::onMessage(const bithorde::HandShake& msg)
{
	bithorde::Client::onMessage(msg);
	cerr << "Connected: " << msg.name() << endl;
}

void Client::onMessage(const bithorde::BindWrite& msg)
{
	if (msg.has_linkpath()) {
		fs::path path(msg.linkpath());
		if (!(path.is_absolute() &&
			_server.linkAsset(path, boost::bind(&Client::onLinkHashDone, this, msg.handle(), _1))))
		{
			cerr << "Upload did not match any allowed assetStore: '" << path << '\'' << endl;
			bithorde::AssetStatus resp;
			resp.set_handle(msg.handle());
			resp.set_status(bithorde::ERROR);
			sendMessage(bithorde::Connection::AssetStatus, resp);
		}
	} else {
		cerr << "Sorry, upload isn't supported yet" << endl;
		bithorde::AssetStatus resp;
		resp.set_handle(msg.handle());
		resp.set_status(bithorde::ERROR);
		sendMessage(bithorde::Connection::AssetStatus, resp);
	}
}

void Client::onMessage(const bithorde::BindRead& msg)
{
	cerr << peerName() << " requested: " << MagnetURI(msg) << endl;

	bithorde::Client::onMessage(msg);
}

void Client::onLinkHashDone(bithorde::Asset::Handle handle, Asset::Ptr a)
{
	bithorde::AssetStatus resp;
	resp.set_handle(handle);
	if (a && a->getIds(*resp.mutable_ids())) {
		resp.set_status(bithorde::SUCCESS);
		resp.set_availability(1000);
		resp.set_size(a->size());
	} else {
		resp.set_status(bithorde::ERROR);
	}
	
	sendMessage(bithorde::Connection::AssetStatus, resp);
}
