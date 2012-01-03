/*
    Copyright 2011 <Ulrik Mikaelsson> <ulrik.mikaelsson@gmail.com>

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


#ifndef CONNECTION_H
#define CONNECTION_H

#include <Poco/Net/Socket.h>
#include <string>

class Connection
{
  using Poco::Net::Socket;
  using std::string;
private:
  Socket s;
  string name;
public: 
  Connection (Socket s, string name);
};

#endif // CONNECTION_H
