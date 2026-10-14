#!/bin/bash
# Collects everything needed to debug a crash / hang into build/diag/ (git-ignored).
# Usage: scripts/collect-diagnostics.sh [minutes-of-log, default 120]
set -u
cd "$(dirname "$0")/.."
MIN="${1:-120}"
OUT="build/diag/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
LIB="$HOME/Library/Application Support/EchoMinutes"

echo "▶ Crash reports (last 2 days)"
find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 2 -iname 'EchoMinutes*' -mtime -2 -print -exec cp {} "$OUT/" \; 2>/dev/null

echo "▶ Unified log (info+debug, last ${MIN} min)"
log show --last "${MIN}m" --info --debug --style compact \
  --predicate 'subsystem == "com.tanimkabir.echominutes" OR (process == "EchoMinutes" AND messageType == fault)' \
  > "$OUT/echominutes.log" 2>&1
wc -l < "$OUT/echominutes.log" | xargs echo "  lines:"

echo "▶ Detection log + latest session manifests"
cp "$LIB/Logs/detection.log" "$OUT/" 2>/dev/null
ls -t "$LIB/Sessions" 2>/dev/null | head -3 | while read -r s; do
  cp "$LIB/Sessions/$s/manifest.json" "$OUT/manifest-$s.json" 2>/dev/null
  ls -la "$LIB/Sessions/$s" > "$OUT/files-$s.txt" 2>/dev/null
done

if pgrep -x EchoMinutes >/dev/null; then
  echo "▶ EchoMinutes is running — sampling 5 s (shows where it is stuck if the menu hangs)"
  sample EchoMinutes 5 -file "$OUT/sample.txt" >/dev/null 2>&1
fi
sw_vers > "$OUT/system.txt"; sysctl -n machdep.cpu.brand_string >> "$OUT/system.txt"
echo "✔ Saved to $OUT"
ls "$OUT"
