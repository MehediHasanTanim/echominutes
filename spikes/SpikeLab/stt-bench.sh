#!/usr/bin/env bash
# EM-012 — benchmark several WhisperKit models over the captured call recordings (or given files).
# Usage: stt-bench.sh [file …]      default: all output/capture-*.wav
# Env:   MODELS="base small large-v3-v20240930_turbo"   LANG_OPT="--lang en" (optional)
set -euo pipefail
cd "$(dirname "$0")"
MODELS="${MODELS:-base small large-v3-v20240930_turbo}"
if [[ $# -gt 0 ]]; then FILES=("$@"); else FILES=(output/capture-*.wav); fi
REL=(); for f in "${FILES[@]}"; do REL+=("$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"); done
./build.sh release > build-output.tmp 2>&1 || { cat build-output.tmp; rm -f build-output.tmp; exit 1; }
rm -f build-output.tmp
for m in $MODELS; do
  echo; echo "████ model: $m"
  BUILD=0 ./run.sh transcribe "${REL[@]}" --model "$m" ${LANG_OPT:-}
done
echo; echo "── Results (output/stt-bench.csv) ──"
column -s, -t < output/stt-bench.csv | tail -n $(( ${#REL[@]} * $(wc -w <<<"$MODELS") + 1 ))
