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

#include "treestore.hpp"

#include <boost/assert.hpp>

uint32_t calc_leaves(uint32_t treesize, int layers)
{
	if (treesize == 0) return 0;
	if (layers == 0) return 1;
	uint32_t leftside = 1 << layers;
	if (leftside <= treesize)
		return (1<<(layers-1)) + calc_leaves(treesize-leftside, layers-1);
	else
		return calc_leaves(treesize-1, layers-1);
}

uint32_t calc_leaves(uint32_t treesize) {
	BOOST_ASSERT(treesize >= 1);
	uint32_t layers = (int)log2f(treesize);
	return calc_leaves(treesize, layers);
}

std::ostream& operator<<(std::ostream& str, const NodeIdx& idx)
{
	return str << "NodeIdx("<<idx.nodeIdx<<','<<idx.layerSize<<')';
}