#!/usr/bin/env bash
# EM-007 (automated) — install a background logger that records every audio-process mic/output
# change to CSV while you use your Mac normally. No manual test sessions needed: your real
# meetings become the dataset. Stop any time with passive/uninstall.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
LABEL="com.tanimkabir.echominutes.spikelab.monitor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
./build.sh release >/dev/null
BIN="$PWD/build/SpikeLab.app/Contents/MacOS/SpikeLab"
mkdir -p output/passive "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$BIN</string><string>processes</string><string>--quiet</string><string>--duration</string><string>21600</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>StandardOutPath</key><string>$PWD/output/passive/monitor.log</string>
  <key>StandardErrorPath</key><string>$PWD/output/passive/monitor.log</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "✔ Background audio-process logger running (restarts every 6 h with a new CSV, starts at login)."
echo "  CSVs: spikes/SpikeLab/output/processes-*.csv   (no audio is recorded — only on/off events)"
echo "  Use your Mac and meeting apps normally for a few days, then run:"
echo "    python3 spikes/SpikeLab/passive/calls.py"
echo "  Stop: spikes/SpikeLab/passive/uninstall.sh"
