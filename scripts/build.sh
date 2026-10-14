#!/usr/bin/env bash
# Build EchoMinutes with xcodebuild and verify signing / hardened runtime / entitlements / Info.plist.
# Usage: scripts/build.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"
[[ -d EchoMinutes.xcodeproj ]] || scripts/bootstrap.sh
mkdir -p build
echo "▶ xcodebuild ($CONFIG)…"
if ! xcodebuild -project EchoMinutes.xcodeproj -scheme EchoMinutes -configuration "$CONFIG" \
      -derivedDataPath build/DerivedData -allowProvisioningUpdates build > build/xcodebuild.log 2>&1; then
  grep -E "error:|warning:" build/xcodebuild.log | sort -u | head -40
  echo "✘ Build failed — full log: build/xcodebuild.log"; exit 1
fi
APP="build/DerivedData/Build/Products/$CONFIG/EchoMinutes.app"
WARN=$(grep -E "warning:" build/xcodebuild.log | grep -vc "appintentsmetadataprocessor" || true)
echo "✔ Built $APP ($WARN warnings)"

echo "▶ Verifying bundle"
ok(){ printf "  ✔ %s\n" "$*"; }; bad(){ printf "  ✘ %s\n" "$*"; FAIL=1; }; FAIL=0
SIG="$(codesign -dvv "$APP" 2>&1)"
echo "$SIG" | grep -q "flags=.*runtime" && ok "Hardened Runtime" || bad "Hardened Runtime missing"
TEAM="$(echo "$SIG" | sed -n 's/^TeamIdentifier=//p')"; [[ -n "$TEAM" && "$TEAM" != "not set" ]] && ok "Team $TEAM" || bad "No team (ad-hoc signed?)"
ENT="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
echo "$ENT" | grep -q "com.apple.security.device.audio-input" && ok "audio-input entitlement" || bad "audio-input entitlement missing"
echo "$ENT" | grep -q "com.apple.security.app-sandbox" && bad "App Sandbox is ON" || ok "No App Sandbox"
PL="$APP/Contents/Info.plist"
for k in NSMicrophoneUsageDescription NSAudioCaptureUsageDescription; do
  /usr/libexec/PlistBuddy -c "Print :$k" "$PL" >/dev/null 2>&1 && ok "$k" || bad "$k missing"; done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$PL" 2>/dev/null)" == "true" ]] && ok "LSUIElement (menu bar agent)" || bad "LSUIElement not set"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PL")" == "com.tanimkabir.echominutes" ]] && ok "Bundle ID com.tanimkabir.echominutes" || bad "Unexpected bundle ID"
(( FAIL )) && { echo "✘ Verification failed"; exit 1; } || echo "✔ All checks passed"
