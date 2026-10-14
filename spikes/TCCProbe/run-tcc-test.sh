#!/usr/bin/env bash
# EM-002 — Confirm microphone permission persists across rebuilds with a stable signing identity.
# Usage: run-tcc-test.sh [identity]        default identity: "Apple Development"
#        run-tcc-test.sh -                 ad-hoc signing (expected to FAIL — shows why a real identity matters)
set -euo pipefail
cd "$(dirname "$0")"
IDENTITY="${1:-Apple Development}"
BUNDLE_ID="com.tanimkabir.echominutes.tccprobe"
mkdir -p output; LOG="$PWD/output/tcc-test.log"; : > "$LOG"

echo "▶ Resetting microphone permission for $BUNDLE_ID (clean start)"
tccutil reset Microphone "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "▶ Run 1: build + launch — macOS SHOULD show a microphone prompt. Click Allow."
./build.sh "$IDENTITY"
open -W -n build/TCCProbe.app --args "$LOG"

sleep 1
echo "▶ Run 2: rebuild (new binary) + launch — there should be NO prompt."
./build.sh "$IDENTITY"
open -W -n build/TCCProbe.app --args "$LOG"

echo; echo "── Log ──"; cat "$LOG"; echo
RUN2="$(tail -1 "$LOG")"
if [[ "$RUN2" == *"before=authorized prompted=no"* ]]; then
  echo "RESULT: ✔ PASS — permission persisted across rebuild with identity '$IDENTITY'"
elif [[ "$RUN2" == *"before=denied prompted=no"* ]]; then
  echo "RESULT: ✔ PASS (persistence) — but you clicked Don't Allow in run 1. Re-run and click Allow."
else
  echo "RESULT: ✘ FAIL — second build was not recognised as the same app ($RUN2)"
  [[ "$IDENTITY" == "-" ]] && echo "        (Expected with ad-hoc signing — use your Apple Development identity.)"
  exit 1
fi
