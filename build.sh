#!/bin/bash
# Builds ClaudeUsage.app next to this script. Needs Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

command -v swiftc >/dev/null || { echo "swiftc not found — run: xcode-select --install"; exit 1; }

APP="ClaudeUsage.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Universal binary: runs on Apple Silicon and Intel Macs.
TMP="$(mktemp -d)"
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos12.0" \
    ClaudeUsage.swift -o "$TMP/ClaudeUsage-$arch"
done
lipo -create "$TMP/ClaudeUsage-arm64" "$TMP/ClaudeUsage-x86_64" -output "$APP/Contents/MacOS/ClaudeUsage"
rm -rf "$TMP"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ClaudeUsage</string>
  <key>CFBundleIdentifier</key><string>local.claude-usage-widget</string>
  <key>CFBundleExecutable</key><string>ClaudeUsage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP — start it with: open $APP"

# bash build.sh --zip  → also makes ClaudeUsage.zip to send to teammates
if [[ "${1:-}" == "--zip" ]]; then
  rm -f ClaudeUsage.zip
  STAGE="$(mktemp -d)/ClaudeUsage"
  mkdir -p "$STAGE"
  cp -R "$APP" README.md "$STAGE/"
  ditto -c -k --norsrc --noextattr --keepParent "$STAGE" ClaudeUsage.zip
  rm -rf "$(dirname "$STAGE")"
  echo "Packaged ClaudeUsage.zip"
fi
