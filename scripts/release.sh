#!/bin/sh
# Tags a release. GitHub Actions builds it, publishes fwd.zip and updates the
# Homebrew tap. Usage: scripts/release.sh 1.2.3
set -eu

VERSION="${1:?usage: scripts/release.sh <version, like 1.2.3>}"
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "Version must look like 1.2.3" >&2; exit 1; }

cd "$(dirname "$0")/.."
[ -z "$(git status --porcelain)" ] || { echo "Commit or stash your changes first." >&2; exit 1; }
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "Release from main." >&2; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "v$VERSION already exists." >&2; exit 1; }

make test
git tag -a "v$VERSION" -m "fwd $VERSION"
git push origin main "v$VERSION"
echo "Pushed v$VERSION. Watch: https://github.com/kylefritz/fwd/actions"
