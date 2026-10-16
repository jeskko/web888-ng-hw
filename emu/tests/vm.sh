#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Drive the emulator's serial console from scripts.
#   tests/vm.sh start [run.sh options]   boot in the background
#   tests/vm.sh send 'command'           type a line on the console
#   tests/vm.sh wait 'regex' [secs]      wait for output matching regex
#   tests/vm.sh run 'command' [secs]     send, wait for the prompt, print output
#   tests/vm.sh log                      console log so far
#   tests/vm.sh stop
set -euo pipefail
EMU=$(cd "$(dirname "$0")/.." && pwd)
D=${VM_DIR:-$EMU/build/vm}
mkdir -p "$D"
PROMPT='web-888:~# '

clean() { tr -d '\r' < "$D/console.log" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g'; }

case "${1:-}" in
start)
    shift
    "$0" stop 2>/dev/null || true
    rm -f "$D/in" "$D/console.log"
    mkfifo "$D/in"
    # keep the fifo open for writing so qemu never sees EOF
    (exec 3<>"$D/in"; exec "$EMU/run.sh" --snapshot "$@" <&3 \
        >"$D/console.log" 2>&1) &
    echo $! > "$D/pid"
    ;;
send)
    printf '%s\r' "$2" > "$D/in"
    ;;
wait)
    t=${3:-120}
    for ((i = 0; i < t * 2; i++)); do
        clean | grep -Eq -- "$2" && exit 0
        sleep 0.5
    done
    echo "timeout waiting for: $2" >&2
    exit 1
    ;;
run)
    n=$(clean | grep -c -- "$PROMPT" || true)
    "$0" send "$2"
    t=${3:-60}
    for ((i = 0; i < t * 2; i++)); do
        m=$(clean | grep -c -- "$PROMPT" || true)
        [ "$m" -gt "$n" ] && break
        sleep 0.5
    done
    clean | awk -v n="$n" -v p="$PROMPT" \
        'index($0, p) { c++ } c > n' | sed '$d'
    ;;
log)
    clean
    ;;
stop)
    if [ -f "$D/pid" ]; then
        pkill -P "$(cat "$D/pid")" 2>/dev/null || true
        kill "$(cat "$D/pid")" 2>/dev/null || true
        rm -f "$D/pid"
    fi
    ;;
*)
    sed -n '3,10p' "$0"
    exit 1
    ;;
esac
