#!/bin/bash

if [ $# -ne 1 ]; then
  echo "Small script to build releases in a consistent and nice manner."
  echo "Usage: $0 <version>"
  exit -1
fi

cd `dirname $0`

VERSION=$1
BASEDIR=releases
VERSIONDIR="bithorde-$VERSION"
PKGDIR="$BASEDIR/$VERSIONDIR"

# Currently we're still in alpha state, so build with debug-stuff
dsss build -g

# Run release-tests
./tests/roundtrip/test_roundtrip.sh
if [ $? == 0 ]; then
  if [ -d "$PKGDIR" ]; then rm -rf "$PKGDIR"; fi
  mkdir -p "$PKGDIR"

  cp sample.config bithorded bhget bhupload "$PKGDIR"
  cd "$BASEDIR"
  tar -zcvf "$VERSIONDIR.tar.gz" "$VERSIONDIR"

  git tag $VERSION
else
  echo "Failed roundtrip-test"
  exit -1
fi
