#!/usr/bin/env bash
# Build (Debug) and launch EchoMinutes. Look for the waveform icon in the menu bar.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh Debug
APP="build/DerivedData/Build/Products/Debug/EchoMinutes.app"
# Quit a running copy (incl. one started at login) and wait until it is really gone —
# launching while it is still terminating makes `open` fail with LaunchServices error -600.
if pgrep -x EchoMinutes >/dev/null; then
  osascript -e 'tell application id "com.tanimkabir.echominutes" to quit' >/dev/null 2>&1 || pkill -x EchoMinutes || true
  for _ in $(seq 1 25); do pgrep -x EchoMinutes >/dev/null || break; sleep 0.2; done
  pkill -9 -x EchoMinutes 2>/dev/null || true
  sleep 0.3
fi
for attempt in 1 2 3; do
  if open "$APP" 2>/dev/null; then echo "✔ Launched — check the menu bar for the waveform icon"; exit 0; fi
  sleep 1
done
echo "✘ Could not launch $APP (LaunchServices). Try: open \"$APP\""; exit 1
