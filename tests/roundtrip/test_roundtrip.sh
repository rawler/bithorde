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

cd $(dirname $0)

source ../common.sh
TESTFILE=testfile
TESTSIZE=4

function clean() {
    rm -rf cache? *.log "$TESTFILE"{,.new}
}

function setup() {
    mkdir cachea cacheb
}

clean && setup || exit_error "Failed setup"

echo "Starting up Nodes..."
trap stop_children EXIT
daemon_start a && DAEMON1=$DAEMONPID
daemon_start b && DAEMON2=$DAEMONPID

echo "Preparing testfile..."
create_testfile $TESTFILE $TESTSIZE

echo "Uploading to A..."
MAGNETURL=$("$BHUPLOAD" -u/tmp/bithorde-rta "$TESTFILE"|grep '^magnet:')
verify_equal cachea/?????????????????????* "$TESTFILE" || exit_error "Uploaded file did not match upload source"
verify_done cacheb/?????????????????????* || exit_error "Uploaded file still has an index, indicating not done"

echo "Getting (2 in parallel) from B..."
"$BHGET" -u/tmp/bithorde-rtb -sy "$MAGNETURL" | verify_equal $TESTFILE || exit_error "Downloaded file did not match upload source" &
wait_until_found "a.log" 'serving [0-9A-Fa-f]* from cache'
"$BHGET" -u/tmp/bithorde-rtb -sy "$MAGNETURL" | verify_equal $TESTFILE || exit_error "Downloaded file did not match upload source"
wait $!
verify_done cacheb/?????????????????????* || exit_error "Cached asset still has an index, indicating not done"
verify_equal cacheb/?????????????????????* "$TESTFILE" || exit_error "File wasn't cached properly"
[ $(grep -c 'serving [0-9A-Fa-f]* from cache' a.log) -eq 1 ] || exit_error "File was doubly-transfered from node A"

echo "Shutting down A..."
quiet_stop $DAEMON1

echo "Re-Getting from B..."
"$BHGET" -u/tmp/bithorde-rtb -sy "$MAGNETURL" | verify_equal "$TESTFILE" || exit_error "Re-Download from cache failed"

exit_success