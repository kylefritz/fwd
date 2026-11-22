#!/bin/sh
# In a workflow, before `make app`: gets the runner ready to sign the app
# with the Developer ID certificate and have Apple notarize it, then hands
# scripts/bundle.sh its settings through $GITHUB_ENV.
#
# Reads these from the environment (repository secrets):
#   DEVELOPER_ID_P12           the certificate and its private key, a .p12 file, base64
#   DEVELOPER_ID_P12_PASSWORD  the password that .p12 was exported with
#   NOTARY_KEY_P8              an App Store Connect API key, the .p8 file's text
#   NOTARY_KEY_ID              that key's ID
#   NOTARY_ISSUER_ID           the issuer ID shown above the keys list
#
# With no certificate the build stays ad-hoc signed, as a fork's would. With
# a certificate but no API key it is signed and not notarized. Each case
# says so with a warning on the run.
set -eu

if [ -z "${DEVELOPER_ID_P12:-}" ]; then
  echo "::warning::Not signed with a Developer ID: the DEVELOPER_ID_P12 secret is empty, so this build is ad-hoc signed."
  exit 0
fi

# A keychain of its own, since the runner's login keychain asks before it
# lets codesign use a key.
KEYCHAIN="$RUNNER_TEMP/signing.keychain-db"
KEYCHAIN_PASSWORD=$(uuidgen)
P12="$RUNNER_TEMP/developer-id.p12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
printf '%s' "$DEVELOPER_ID_P12" | base64 --decode > "$P12"
security import "$P12" -k "$KEYCHAIN" -P "${DEVELOPER_ID_P12_PASSWORD:-}" -T /usr/bin/codesign
rm -f "$P12"
# Without this, codesign stops to ask for the keychain password.
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
# codesign looks through the keychains on the search list.
# shellcheck disable=SC2046
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN" \
  | awk -F'"' '/Developer ID Application/ { print $2; exit }')
if [ -z "$IDENTITY" ]; then
  echo "::error::DEVELOPER_ID_P12 holds no valid Developer ID Application certificate (expired, revoked, or exported without its private key)."
  security find-identity -p codesigning "$KEYCHAIN" >&2 || true
  exit 1
fi
echo "Signing as $IDENTITY"
echo "SIGN_IDENTITY=$IDENTITY" >> "$GITHUB_ENV"

if [ -z "${NOTARY_KEY_P8:-}" ] || [ -z "${NOTARY_KEY_ID:-}" ] || [ -z "${NOTARY_ISSUER_ID:-}" ]; then
  echo "::warning::Signed but not notarized: NOTARY_KEY_P8, NOTARY_KEY_ID and NOTARY_ISSUER_ID aren't all set, so macOS still warns about a downloaded copy."
  exit 0
fi
KEY="$RUNNER_TEMP/notary.p8"
(umask 077; printf '%s\n' "$NOTARY_KEY_P8" > "$KEY")
{
  echo "NOTARY_KEY=$KEY"
  echo "NOTARY_KEY_ID=$NOTARY_KEY_ID"
  echo "NOTARY_ISSUER=$NOTARY_ISSUER_ID"
} >> "$GITHUB_ENV"
echo "Apple will notarize this build"
