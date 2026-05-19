#!/bin/bash
# Builds ClaudeViewer.app from the Swift package and installs it to
# ~/Applications. Does not leave a stray copy in the project directory
# (so Spotlight only sees one app).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="ClaudeViewer.app"
INSTALL_DIR="$HOME/Applications"
INSTALL_PATH="$INSTALL_DIR/$APP_NAME"

echo "==> Building release binary"
swift build -c release

# Assemble into a temp dir then atomically swap into place.
STAGE="$(mktemp -d)"
APP="$STAGE/$APP_NAME"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/release/ClaudeViewer" "$APP/Contents/MacOS/ClaudeViewer"
chmod +x "$APP/Contents/MacOS/ClaudeViewer"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ClaudeViewer</string>
    <key>CFBundleIdentifier</key>
    <string>com.claudeviewer.app</string>
    <key>CFBundleName</key>
    <string>Claude Viewer</string>
    <key>CFBundleDisplayName</key>
    <string>Claude Viewer</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_PATH"
mv "$APP" "$INSTALL_PATH"
rmdir "$STAGE"

# Make sure we don't leave a build artifact anywhere Spotlight indexes.
rm -rf "$ROOT/dist"

echo "==> Installed: $INSTALL_PATH"
