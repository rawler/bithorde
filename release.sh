#!/bin/bash

if [ $# -ne 1 ]; then
  echo "Small script to build releases in a consistent and nice manner."
  echo "Usage: $0 <version>"
  exit -1
fi

cd `dirname $0`

VERSION=$1
PKGDIR=releases/bithorde-$VERSION

# Currently we're still in alpha state, so build with debug-stuff
dsss build -g

if [ -d "$PKGDIR" ]; then
  rm -rf "$PKGDIR"
fi

mkdir -p "$PKGDIR"
cp sample.config server bhget bhupload "$PKGDIR"

tar -zcvf "$PKGDIR.tar.gz" "$PKGDIR"

git tag $VERSION
