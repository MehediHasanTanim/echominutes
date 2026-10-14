#!/usr/bin/env bash
# EM-007 — Guided detection-timeline recording for one meeting app.
# Runs `processes --filter <app>` in the background and records your step markers
# (press Enter at each step) so the mic/output timeline can be analysed per call moment.
#
# Usage: scenario.sh teams|zoom|whatsapp
set -euo pipefail
cd "$(dirname "$0")"
APP="${1:-}"
case "$APP" in
  teams)    FILTER="teams";    NAME="Microsoft Teams" ;;
  zoom)     FILTER="zoom";     NAME="Zoom" ;;
  whatsapp) FILTER="whatsapp"; NAME="WhatsApp" ;;
  *) echo "Usage: $0 teams|zoom|whatsapp"; exit 2 ;;
esac

./build.sh > build-output.tmp 2>&1 || { cat build-output.tmp; rm -f build-output.tmp; exit 1; }
rm -f build-output.tmp
mkdir -p output
TS="$(date +%Y%m%d-%H%M%S)"
LOG="$PWD/output/$TS-scenario-$APP.log"
MARKERS="$PWD/output/scenario-$APP-$TS.markers.csv"
echo "epoch_ms,step" > "$MARKERS"

mark() {   # mark <step_id>
  local ms; ms=$(python3 -c 'import time;print(int(time.time()*1000))')
  echo "$ms,$1" >> "$MARKERS"
  printf "   \033[32m✔ marked '%s' at %s\033[0m\n" "$1" "$(date +%H:%M:%S)"
}
step() {   # step <step_id> <instruction> [wait_seconds]
  echo; printf "\033[1m▶ %s\033[0m\n" "$2"
  read -r -p "   Press Enter the moment you've done it… " _
  mark "$1"
  if [[ -n "${3:-}" ]]; then
    for ((i=$3; i>0; i--)); do printf "\r   waiting %2ds (don't change anything)…" "$i"; sleep 1; done; printf "\r%-50s\n" "   done."
  fi
}

echo "== EM-007 scenario: $NAME =="
echo "Make sure $NAME is QUIT (⌘Q) before starting. Have your phone / other person ready."
read -r -p "Press Enter to start monitoring… " _
open -n --stdout "$LOG" --stderr "$LOG" build/SpikeLab.app --args processes --filter "$FILTER"
sleep 2
mark "monitor_started"

step app_launched     "Open $NAME (launch the app). Do NOT start or join a call."                    20
case "$APP" in
  whatsapp)
    step call_started   "Start a voice call to the other person (it should be ringing now)."          0
    step call_answered  "The other person answers. Both talk normally."                              20 ;;
  *)
    step prejoin_screen "Start/open a meeting and stop on the pre-join screen (camera/mic preview). Don't click Join yet." 15
    step joined         "Click Join now. Talk normally (have the phone talk too)."                     20 ;;
esac
step muted            "Mute your microphone in $NAME. Stay silent."                                   20
step unmuted          "Unmute. Talk again."                                                          10
step left_call        "Leave / end the call. Stay on whatever screen $NAME shows."                     20
step app_idle_after   "Leave $NAME open and idle (no call)."                                          15
step app_quit         "Quit $NAME completely (⌘Q)."                                                    5

pkill -TERM -f "SpikeLab.app/Contents/MacOS/SpikeLab" 2>/dev/null || true
sleep 1
mark "monitor_stopped"
CSV="$(ls -t output/processes-*.csv | head -1)"
echo
echo "Done. Files:"
echo "  events : spikes/SpikeLab/$CSV"
echo "  markers: spikes/SpikeLab/${MARKERS#$PWD/}"
echo "  log    : spikes/SpikeLab/${LOG#$PWD/}"
echo "Analyse with: python3 spikes/SpikeLab/timeline.py spikes/SpikeLab/$CSV spikes/SpikeLab/${MARKERS#$PWD/}"
