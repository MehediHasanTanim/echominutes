#!/usr/bin/env bash
# Run all EchoMinutesKit unit tests (Swift Testing) — fast, no Xcode project needed.
# Usage: scripts/test.sh [filter]     e.g. scripts/test.sh EMDetection
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
ARGS=(--package-path Packages/EchoMinutesKit)
[[ -n "${1:-}" ]] && ARGS+=(--filter "$1")
if swift test "${ARGS[@]}" > build/swift-test.log 2>&1; then
  grep -E "Test run with|passed after|✔" build/swift-test.log | tail -5
  echo "✔ Tests passed (log: build/swift-test.log)"
else
  grep -E "error:|✘|failed|issue" build/swift-test.log | head -40
  echo "✘ Tests failed (log: build/swift-test.log)"; exit 1
fi
