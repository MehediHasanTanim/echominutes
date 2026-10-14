#!/usr/bin/env bash
# Launch SpikeLab.app as a real app (so TCC permissions belong to SpikeLab) and stream its output.
# Usage: run.sh [command] [args…]     e.g. run.sh all | run.sh mic | run.sh tap-probe
#        BUILD=0 run.sh …              skip rebuilding
set -euo pipefail
cd "$(dirname "$0")"
if [[ "${BUILD:-1}" == "1" ]]; then
  ./build.sh > build-output.tmp 2>&1 || { cat build-output.tmp; rm -f build-output.tmp; exit 1; }
  rm -f build-output.tmp
fi
mkdir -p output
LOG="$PWD/output/$(date +%Y%m%d-%H%M%S)-${1:-all}.log"; : > "$LOG"

open -W -n --stdout "$LOG" --stderr "$LOG" build/SpikeLab.app --args "$@" &
OPEN_PID=$!
tail -n +1 -f "$LOG" & TAIL_PID=$!
stop_tail() { kill $TAIL_PID 2>/dev/null || true; wait $TAIL_PID 2>/dev/null || true; }
trap stop_tail EXIT
# Ctrl+C: ask the app (launched by launchd, not our child) to stop cleanly, then show its final output.
STOPPED=0
trap 'STOPPED=1; pkill -TERM -f "SpikeLab.app/Contents/MacOS/SpikeLab" 2>/dev/null || true' INT
wait $OPEN_PID || true
if (( STOPPED )); then
  # wait for the app to flush its final table (tail keeps streaming it), then stop tail
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "SpikeLab.app/Contents/MacOS/SpikeLab" >/dev/null || break; sleep 0.3; done
  sleep 0.3
fi
stop_tail
sleep 0.3
echo "(log saved: ${LOG#$PWD/})"
