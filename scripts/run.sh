#!/usr/bin/env bash
# Build (Debug) and launch EchoMinutes. Look for the waveform icon in the menu bar.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh Debug
pkill -x EchoMinutes 2>/dev/null || true
open "build/DerivedData/Build/Products/Debug/EchoMinutes.app"
echo "✔ Launched — check the menu bar for the waveform icon"
