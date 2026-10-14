#!/usr/bin/env bash
# Generate EchoMinutes.xcodeproj from project.yml (installs XcodeGen via Homebrew if missing).
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodegen >/dev/null; then
  if command -v brew >/dev/null; then
    echo "▶ Installing XcodeGen (brew install xcodegen)…"; brew install xcodegen
  else
    echo "✘ XcodeGen not found and Homebrew missing. Install Homebrew (https://brew.sh) then: brew install xcodegen"; exit 1
  fi
fi
[[ -f Config/Signing.local.xcconfig ]] || { echo "▶ No Config/Signing.local.xcconfig — running signing check"; scripts/check-signing.sh --write-local; }
xcodegen generate --spec project.yml --quiet
echo "✔ Generated EchoMinutes.xcodeproj — open with: xed ."
