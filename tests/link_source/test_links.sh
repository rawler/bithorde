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

TESTFILE=$SOURCE_ROOT/testfile
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

echo "Preparing testfile..."
create_testfile $TESTFILE $TESTSIZE

echo "Uploading testfile..."
MAGNETURL=$("$BHUPLOAD" -u$DAEMON_SOCKET -l "$TESTFILE"|grep '^magnet:')
VERIFICATION=$("$BHUPLOAD" -u$DAEMON_SOCKET -l "$TESTFILE"|grep '^magnet:')
[ "$MAGNETURL" == "$VERIFICATION" ] || exit_error "Re-upload with different magnet-link ($MAGNETURL vs. $VERIFICATION)".

echo "Getting testfile..."
"$BHGET" -u$DAEMON_SOCKET "$MAGNETURL" | verify_equal $TESTFILE & DL1=$!
wait $DL1 || exit_error "Downloaded file did not match upload source"

echo "Verifying clear after mtime-change..."
sleep 1; touch "$TESTFILE"
"$BHGET" -u$DAEMON_SOCKET "$MAGNETURL" &>/dev/null && exit_error "Touching source did not break link"

VERIFICATION=$("$BHUPLOAD" -u$DAEMON_SOCKET -l "$TESTFILE"|grep '^magnet:')
[ "$MAGNETURL" == "$VERIFICATION" ] || exit_error "Restored with different magnet-link ($MAGNETURL vs. $VERIFICATION)".

echo "Getting testfile..."
"$BHGET" -u$DAEMON_SOCKET "$MAGNETURL" | verify_equal $TESTFILE & DL1=$!
wait $DL1 || exit_error "Re-downloaded file did not match upload source"

echo "Verifying clear after content-change..."
sleep 1; create_testfile $TESTFILE $(($TESTSIZE * 2))
"$BHGET" -u$DAEMON_SOCKET "$MAGNETURL" &>/dev/null && exit_error "Modifying source did not break link"

MAGNETURL1=$("$BHUPLOAD" -u$DAEMON_SOCKET -l "$TESTFILE"|grep '^magnet:')
[ "$MAGNETURL" != "$MAGNETURL1" ] || exit_error "Restored with same magnet-link ($MAGNETURL vs. $MAGNETURL1)".

echo "Getting testfile..."
"$BHGET" -u$DAEMON_SOCKET "$MAGNETURL1" | verify_equal $TESTFILE & DL1=$!
wait $DL1 || exit_error "Re-downloaded file did not match upload source"

exit_success