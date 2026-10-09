#!/bin/sh
# Points the Homebrew formula at a released version and pushes it to the tap.
# Usage: TAP_TOKEN=... scripts/update-formula.sh 1.2.3
set -eu

VERSION="$1"
REPO="kylefritz/fwd"
TAP="kylefritz/homebrew-tap"
URL="https://github.com/$REPO/archive/refs/tags/v$VERSION.tar.gz"

cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
# Download to a file first: in a pipeline a failed curl would still yield
# the checksum of nothing.
curl -fsSL -o "$WORK/source.tar.gz" "$URL" || { echo "Couldn't fetch $URL" >&2; exit 1; }
[ -s "$WORK/source.tar.gz" ] || { echo "Empty download from $URL" >&2; exit 1; }
SHA=$(shasum -a 256 "$WORK/source.tar.gz" | cut -d' ' -f1)

git clone --quiet "https://x-access-token:${TAP_TOKEN}@github.com/$TAP.git" "$WORK/tap"
mkdir -p "$WORK/tap/Formula"
sed -e "s|^  url .*|  url \"$URL\"|" -e "s|^  sha256 .*|  sha256 \"$SHA\"|" \
  Formula/fwd.rb > "$WORK/tap/Formula/fwd.rb"

cd "$WORK/tap"
git add Formula/fwd.rb
if git diff --cached --quiet; then
  echo "Formula already at $VERSION"
  exit 0
fi
git -c user.name="fwd release" -c user.email="noreply@github.com" commit --quiet -m "fwd $VERSION"
git push --quiet
echo "Tap updated to $VERSION"
