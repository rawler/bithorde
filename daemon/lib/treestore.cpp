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


#include "treestore.hpp"

uint bottomlayersize(uint treesize, int layers)
{
	if (treesize == 0) return 0;
	if (layers == -1) layers = (int)log2f(treesize);
	if (layers == 0) return 1;
	uint leftside = 1 << layers;
	if (leftside <= treesize)
		return (1<<(layers-1)) + bottomlayersize(treesize-leftside, layers-1);
	else
		return bottomlayersize(treesize-1, layers-1);
}

std::ostream& operator<<(std::ostream& str, const NodeIdx& idx)
{
	return str << "NodeIdx("<<idx.nodeIdx<<','<<idx.layerSize<<')';
}