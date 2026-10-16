#!/bin/sh
# Assembles build/fwd.app from the release build and ad-hoc signs it.
# Usage: VERSION=1.2.3 scripts/bundle.sh   (VERSION defaults to "dev")
set -eu

cd "$(dirname "$0")/.."
VERSION="${VERSION:-dev}"
# Not `swift build --show-bin-path`: that starts SwiftPM's sandbox, which
# fails inside Homebrew's own build sandbox.
BINARY=".build/release/fwd"
[ -x "$BINARY" ] || { echo "No release binary; run 'swift build -c release' first." >&2; exit 1; }
CLI=".build/release/fwd-cli"
[ -x "$CLI" ] || { echo "No release fwd-cli; run 'swift build -c release' first." >&2; exit 1; }

APP="build/fwd.app"
rm -rf "$APP" build/fwd.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BINARY" "$APP/Contents/MacOS/fwd"
# The terminal command (Sources/fwd-cli), at the path the ~/.local/bin link
# and the Homebrew formula point to.
cp "$CLI" "$APP/Contents/Resources/bin/fwd"
chmod 755 "$APP/Contents/Resources/bin/fwd"

# The icon is drawn by the app itself (Sources/fwd/Icon.swift).
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
"$BINARY" --write-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# The commit it was built from, to tell dev builds apart; "-dirty" means
# uncommitted changes went in too. Empty when building from a source
# tarball, as Homebrew does.
COMMIT=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  COMMIT=$(git rev-parse --short HEAD)
  git diff --quiet HEAD -- || COMMIT="$COMMIT-dirty"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>fwd</string>
  <key>CFBundleDisplayName</key><string>fwd</string>
  <key>CFBundleExecutable</key><string>fwd</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>io.github.kylefritz.fwd</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>FwdCommit</key><string>${COMMIT}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
/usr/bin/ditto -c -k --keepParent "$APP" build/fwd.zip
echo "Built $APP (version $VERSION) and build/fwd.zip"
