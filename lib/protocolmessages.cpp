/*
    Copyright 2013 <copyright holder> <email>

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


#include "protocolmessages.hpp"

template<class T>
bool operator!=(const ::google::protobuf::RepeatedPtrField<T>& a, const ::google::protobuf::RepeatedPtrField<T>& b) {
	if (a.size() != b.size())
		return true;
	for (auto aiter=a.begin(), biter=b.begin(); aiter != a.end(); aiter++, biter++ ) {
		if (*aiter != *biter)
			return true;
	}

	return false;
}

template<class T>
bool operator!=(const ::google::protobuf::RepeatedField<T>& a, const ::google::protobuf::RepeatedField<T>& b) {
	if (a.size() != b.size())
		return true;
	for (auto aiter=a.begin(), biter=b.begin(); aiter != a.end(); aiter++, biter++ ) {
		if (*aiter != *biter)
			return true;
	}

	return false;
}

template<class T>
bool operator==(const ::google::protobuf::RepeatedPtrField<T>& a, const ::google::protobuf::RepeatedPtrField<T>& b) {
	if (a.size() != b.size())
		return false;
	for (auto aiter=a.begin(), biter=b.begin(); aiter != a.end(); aiter++, biter++ ) {
		if (*aiter != *biter)
			return false;
	}

	return true;
}

template<class T>
bool operator==(const ::google::protobuf::RepeatedField<T>& a, const ::google::protobuf::RepeatedField<T>& b) {
	if (a.size() != b.size())
		return false;
	for (auto aiter=a.begin(), biter=b.begin(); aiter != a.end(); aiter++, biter++ ) {
		if (*aiter != *biter)
			return false;
	}

	return true;
}

bool operator!=(const bithorde::AssetStatus& a, const bithorde::AssetStatus& b)
{
	if (a.status() != b.status())
		return true;
	if (a.size() != b.size())
		return true;
	if (a.availability() != b.availability())
		return true;

	if (a.ids() != b.ids()) {
		return true;
	}
	if (a.servers() != b.servers()) {
		return true;
	}

	return false;
}

bool operator!=(const bithorde::Identifier& a, const bithorde::Identifier& b)
{
	return (a.id() != b.id() || a.type() != b.type());
}

bool operator==(const bithorde::AssetStatus& a, const bithorde::AssetStatus& b)
{
	if (a.status() != b.status())
		return false;
	if (a.size() != b.size())
		return false;
	if (a.availability() != b.availability())
		return false;

	if (a.ids() != b.ids()) {
		return false;
	}
	if (a.servers() != b.servers()) {
		return false;
	}

	return true;
}

bool operator==(const bithorde::Identifier& a, const bithorde::Identifier& b)
{
	return (a.id() == b.id()) && (a.type() == b.type());
}

bool std::operator!=(const bithorde::Identifier& a, const bithorde::Identifier& b)
{
	return (a.id() != b.id()) || (a.type() != b.type());
}

bool std::operator==(const bithorde::Identifier& a, const bithorde::Identifier& b)
{
	return (a.id() == b.id()) && (a.type() == b.type());
}
