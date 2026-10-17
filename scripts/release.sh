#!/bin/bash
# EM-138: Release build → verify → install to /Applications → (optional) tag.
# Usage: scripts/release.sh [version]     e.g. scripts/release.sh 1.0.0
# Signing uses your Apple Development identity (fine for your own Mac). Distributing to others needs a
# Developer ID certificate + notarization (paid Apple Developer Program) — see docs/setup/SIGNING.md.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-}"
if [[ -n "$VERSION" ]]; then
  sed -i '' -E "s/(MARKETING_VERSION: ).*/\1\"$VERSION\"/" project.yml && scripts/bootstrap.sh >/dev/null
fi
scripts/test.sh
scripts/build.sh Release
APP="build/DerivedData/Build/Products/Release/EchoMinutes.app"
echo "▶ Installing to /Applications (quits the running copy)"
osascript -e 'tell application id "com.tanimkabir.echominutes" to quit' 2>/dev/null || true
sleep 2
rm -rf /Applications/EchoMinutes.app
ditto "$APP" /Applications/EchoMinutes.app
codesign --verify --deep --strict /Applications/EchoMinutes.app && echo "  ✔ signature valid"
open /Applications/EchoMinutes.app
echo "✔ Installed /Applications/EchoMinutes.app $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/EchoMinutes.app/Contents/Info.plist)"
echo "  Next: Settings ▸ General ▸ Launch at login, and remove any old Debug copy from the Dock/Login Items."
if [[ -n "$VERSION" ]]; then
  git add project.yml App/Info.plist 2>/dev/null || true
  git commit -qm "Release v$VERSION" || true
  git tag -a "v$VERSION" -m "EchoMinutes v$VERSION" && echo "✔ Tagged v$VERSION — push with: git push origin main --tags"
fi
