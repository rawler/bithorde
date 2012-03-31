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


#ifndef BITHORDED_CLIENT_H
#define BITHORDED_CLIENT_H

#include "lib/client.h"
#include "bithorded/store/asset.hpp"

namespace bithorded {

class Server;
class Client : public bithorde::Client
{
	Server& _server;
public:
	static Pointer create(Server& server, std::string myName) {
		return Pointer(new Client(server, myName));
	}

protected:
	Client(Server& server, std::string myName);

	virtual void onMessage(const bithorde::HandShake& msg);
	virtual void onMessage(const bithorde::BindWrite& msg);
	virtual void onMessage(const bithorde::BindRead& msg);

private:
	void onLinkHashDone(bithorde::Asset::Handle handle, bithorded::Asset::Ptr a);
};

}
#endif // BITHORDED_CLIENT_H
