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

A_SOCK=$(readlink -f rta.sock)
B_SOCK=$(readlink -f rtb.sock)
TESTFILE=testfile
TESTSIZE=768

function clean() {
    rm -rf cache? *.log "$TESTFILE"{,.new}
}

function setup() {
    mkdir cachea cacheb
}

clean && setup || exit_error "Failed setup"

echo "Starting up Nodes..."
trap stop_children EXIT
bithorded_start a
bithorded_start b

echo "Preparing testfile..."
create_testfile $TESTFILE $TESTSIZE

echo "Uploading to A..."
MAGNETURL=$("$BHUPLOAD" -d -u$A_SOCK "$TESTFILE"|grep '^magnet:')
VERIFICATION=$("$BHUPLOAD" -u$A_SOCK "$TESTFILE"|grep '^magnet:')
[ "$MAGNETURL" == "$VERIFICATION" ] || exit_error "Re-upload with different magnet-link".

echo "Getting (2 in parallel) from B..."
"$BHGET" -nbhget1 -u$B_SOCK "$MAGNETURL" | verify_equal $TESTFILE & DL1=$!
"$BHGET" -nbhget2 -u$B_SOCK "$MAGNETURL" | verify_equal $TESTFILE & DL2=$!
wait $DL1 && echo "Download 1 succeeded" || exit_error "Download 1 file did not match upload source"
wait $DL2 && echo "Download 2 succeeded" || exit_error "Download 2 file did not match upload source"

exit_success