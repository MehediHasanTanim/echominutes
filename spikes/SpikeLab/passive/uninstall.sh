#!/usr/bin/env bash
set -euo pipefail
LABEL="com.tanimkabir.echominutes.spikelab.monitor"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "✔ logger stopped" || echo "logger was not running"
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
