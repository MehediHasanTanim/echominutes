#!/usr/bin/env bash
# Build SpikeLab with SwiftPM, wrap it in SpikeLab.app, sign with your Apple Development identity + Hardened Runtime.
# Usage: build.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-debug}"
ROOT="$(cd ../.. && pwd)"
APP="build/SpikeLab.app"

# Identity: SHA-1 from Config/Signing.local.xcconfig (written by scripts/check-signing.sh), else by name.
IDENTITY="$(sed -nE 's/^EM_SIGNING_IDENTITY_SHA1 *= *([0-9A-F]+).*/\1/p' "$ROOT/Config/Signing.local.xcconfig" 2>/dev/null || true)"
IDENTITY="${IDENTITY:-Apple Development}"

echo "▶ swift build ($CONFIG)"
mkdir -p build
if ! swift build -c "$CONFIG" --arch arm64 > build/swift-build.log 2>&1; then
  grep -E "error|warning" build/swift-build.log || cat build/swift-build.log
  echo "✘ swift build failed (full log: spikes/SpikeLab/build/swift-build.log)"; exit 1
fi
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/SpikeLab"
[[ -x "$BIN" ]] || { echo "✘ build failed"; exit 1; }

echo "▶ assemble $APP"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/SpikeLab"
sed "s/__BUILD__/$(date +%Y%m%d%H%M%S)/" Resources/Info.plist > "$APP/Contents/Info.plist"

echo "▶ codesign ($IDENTITY)"
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/SpikeLab.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "✔ $APP ready"
