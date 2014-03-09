#!/bin/bash
#
# Copyright (C) 2009-2010 Ulrik Mikaelsson. All rights reserved
#
#   License:
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

CODE_DIR=$(dirname $0)
CODE_ROOT=$(dirname $CODE_DIR)
source $CODE_ROOT/common.sh

SOURCE_ROOT=src
DAEMON_SOCKET=$(readlink -f bithorded.sock)

TESTFILE=$SOURCE_ROOT/sparsefile
TESTSIZE=768

function clean() {
    rm -rf *.log "$TESTFILE"{,.new}
}

function setup() {
    mkdir -p $SOURCE_ROOT
}

clean && setup || exit_error "Failed setup"

echo "Starting up Nodes..."
trap stop_children EXIT
bithorded_start src --server.unixSocket "$DAEMON_SOCKET"

echo "Preparing 4GB sparse testfile..."
create_sparsetestfile $TESTFILE $((4*1024*1024))
echo "Verifying..."
("$BHUPLOAD" -u$DAEMON_SOCKET -l "$TESTFILE"|grep '^magnet:') || exit_error "Failed upload"

echo "Preparing 4GB+ sparse testfile..."
create_sparsetestfile $TESTFILE 4194319 # Fist prime after 4*1024*1024 (size is in kilobytes)
echo "Verifying..."
("$BHUPLOAD" -u$DAEMON_SOCKET -l "$TESTFILE"|grep '^magnet:') || exit_error "Failed upload"

exit_success