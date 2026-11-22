#!/bin/sh
# Assembles build/fwd.app from the release build, signs it and zips it.
# Usage: VERSION=1.2.3 scripts/bundle.sh   (VERSION defaults to "dev")
# PREVIEW="PR #42" marks a pull request's preview build in the footer.
#
# Signing is ad-hoc unless SIGN_IDENTITY names a certificate in the keychain,
# for example "Developer ID Application: Kyle Fritz (75W4LUJ7MW)". With that
# and an App Store Connect API key (NOTARY_KEY, the path to its .p8 file,
# NOTARY_KEY_ID and NOTARY_ISSUER), Apple notarizes the app too, so a
# downloaded copy opens with no Gatekeeper step.
set -eu

cd "$(dirname "$0")/.."
VERSION="${VERSION:-dev}"
PREVIEW="${PREVIEW:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_KEY="${NOTARY_KEY:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${NOTARY_ISSUER:-}"
if [ -n "$NOTARY_KEY" ]; then
  [ -n "$SIGN_IDENTITY" ] || { echo "NOTARY_KEY is set but SIGN_IDENTITY isn't; Apple only notarizes a Developer ID signed app." >&2; exit 1; }
  [ -n "$NOTARY_KEY_ID" ] && [ -n "$NOTARY_ISSUER" ] || { echo "NOTARY_KEY needs NOTARY_KEY_ID and NOTARY_ISSUER too." >&2; exit 1; }
fi
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
# The check fwd runs on a host for the VS Code button's herdr menu.
cp scripts/herdr.sh "$APP/Contents/Resources/herdr.sh"

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
  <key>FwdPreview</key><string>${PREVIEW}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

if [ -n "$SIGN_IDENTITY" ]; then
  # Inside out: the terminal command is a second executable in the bundle,
  # and Apple's notary turns away a bundle holding one that isn't signed
  # with the hardened runtime and a timestamp itself.
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
    --identifier io.github.kylefritz.fwd.cli "$APP/Contents/Resources/bin/fwd"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  SIGNED="signed by $SIGN_IDENTITY"
else
  codesign --force --sign - "$APP"
  SIGNED="ad-hoc signed"
fi
codesign --verify --deep --strict "$APP"
/usr/bin/ditto -c -k --keepParent "$APP" build/fwd.zip

if [ -n "$NOTARY_KEY" ]; then
  # Apple checks the zip and records a ticket for the app; stapling puts the
  # ticket inside the bundle so Gatekeeper accepts it with no network.
  RESULT="build/notary.txt"
  xcrun notarytool submit build/fwd.zip --wait \
    --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" | tee "$RESULT"
  if ! grep -q "status: Accepted" "$RESULT"; then
    # The reasons are only in the submission's log.
    ID=$(awk '/^ *id:/ { print $2; exit }' "$RESULT")
    [ -z "$ID" ] || xcrun notarytool log "$ID" \
      --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" >&2 || true
    echo "Apple's notary did not accept the app." >&2
    exit 1
  fi
  xcrun stapler staple "$APP"
  # Again, so the zip holds the stapled app.
  rm -f build/fwd.zip
  /usr/bin/ditto -c -k --keepParent "$APP" build/fwd.zip
  SIGNED="$SIGNED, notarized"
fi
echo "Built $APP (version $VERSION, $SIGNED) and build/fwd.zip"
