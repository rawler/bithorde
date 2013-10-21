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


#ifndef PROTOCOLMESSAGES_HPP
#define PROTOCOLMESSAGES_HPP

#include "bithorde.pb.h"

template <class Set, typename Iterator>
bool overlaps(const Set& set, const Iterator& begin, const Iterator& end) {
	for (auto iter=begin; iter != end; iter++) {
		if (set.count(*iter)) {
			return true;
		}
	}
	return false;
}

template <typename T, class S>
void setRepeatedField(google::protobuf::RepeatedField<T>* tgt, const S& src) {
	tgt->Clear();
	auto end = src.cend();
	for (auto iter = src.cbegin(); iter != end; iter++) {
		tgt->Add(*iter);
	}
}

template <class T, class S>
void setRepeatedPtrField(google::protobuf::RepeatedPtrField<T>* tgt, const S& src) {
	tgt->Clear();
	auto end = src.cend();
	for (auto iter = src.cbegin(); iter != end; iter++) {
		*(tgt->Add()) = *iter;
	}
}

namespace bithorde {
	bool operator==(const bithorde::AssetStatus& a, const bithorde::AssetStatus& b);
	bool operator!=(const bithorde::AssetStatus& a, const bithorde::AssetStatus& b);
	bool operator==(const bithorde::Identifier& a, const bithorde::Identifier& b);
	bool operator!=(const bithorde::Identifier& a, const bithorde::Identifier& b);
}

namespace std
{
	template<>
	struct hash<bithorde::Identifier >
	{
		typedef bithorde::Identifier argument_type;
		typedef size_t result_type;

		result_type operator()(const argument_type& a) const
		{
			return std::hash<std::string>()(a.id());
		}
	};
}

#endif // PROTOCOLMESSAGES_HPP
