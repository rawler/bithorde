# File with common functions for shell-driven tests.

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

BINDIR="${BH_BINDIR:-"$(readlink -f $(dirname "$BASH_SOURCE")/..)/build/bin"}"
SERVER="$BINDIR/bithorded"
BHUPLOAD="$BINDIR/bhupload"
BHGET="$BINDIR/bhget"

function create_testfile() {
    # $1 - filename
    # $2 - size in MB
    dd if=/dev/urandom of="$1" bs=1048576 count=$2 2>/dev/null
}

function verify_equal() {
    # $1 - reference file
    # $2 - testfile, or skip to test stdin

    if [ -z "$2" ]; then
        cmp - "$1"
    elif [ -e "$2" ]; then
        cmp "$2" "$1"
    else
        return 1;
    fi
}

function verify_done() {
    # Verifies complete asset in cache
    # $1 - cache asset path
    [ ! -e "$1.idx" ]
}

function wait_until_found() {
    # Waits for file to contain pattern
    # $1 - file
    # $2 - pattern
    while [ $(grep -c "$2" "$1") -eq 0 ]; do
      sleep 0.1
    done
}

function exit_error() {
    echo "ERROR: $1"
    exit 1
}

function exit_success() {
    clean
    echo "===== SUCCESS! ====="
    exit 0
}

function bithorded_start() {
    # Start a daemon by name.
    # $1 - daemon name, which maps to <name>.config and <name>.log
    # #2... is passed to bithorded
    config="$CODE_DIR/$1.config"
    logfile="$1.log"
    shift

    stdbuf -o0 -e0 "$SERVER" -c "$config" --server.inspectPort 0 "$@" &> "$logfile" &
    DAEMONPID=$!
    wait_until_found "$logfile" "Server started"
}

function quiet_stop() {
    disown $1 && kill $1
}

function stop_children() {
    for job in `jobs -p`; do
        quiet_stop $job
    done
}
