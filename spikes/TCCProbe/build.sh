#!/usr/bin/env bash
# Build + sign TCCProbe.app.  Usage: build.sh [identity]   (identity = SHA-1, name, or "-" for ad-hoc)
set -euo pipefail
cd "$(dirname "$0")"
IDENTITY="${1:-Apple Development}"
APP="build/TCCProbe.app"
STAMP="$(date +%Y%m%d%H%M%S)"

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" build
echo "let buildStamp = \"$STAMP\"" > build/BuildStamp.swift   # changes the binary every build

swiftc -O -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework AVFoundation \
  main.swift build/BuildStamp.swift -o "$APP/Contents/MacOS/TCCProbe"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.tanimkabir.echominutes.tccprobe</string>
  <key>CFBundleName</key><string>TCCProbe</string>
  <key>CFBundleExecutable</key><string>TCCProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$STAMP</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>EchoMinutes signing test: checks that microphone permission survives rebuilds.</string>
</dict></plist>
PL

codesign --force --options runtime --timestamp=none \
  --entitlements TCCProbe.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (build $STAMP) signed with: $IDENTITY"
echo "Designated requirement:"; codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /  /p'
