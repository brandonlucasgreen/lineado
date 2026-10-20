#!/bin/bash
#
# Fetch Sparkle's command-line tools into .sparkle/ (gitignored).
#
# They ship in the Sparkle release tarball, not in the SPM package, so a clone
# has the framework but none of generate_keys / sign_update / generate_appcast.
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${SPARKLE_VERSION:-2.9.6}"
DEST=".sparkle"

if [ -x "$DEST/bin/sign_update" ]; then
  echo "Sparkle tools already present ($DEST/bin)."
  exit 0
fi

URL="https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Sparkle $VERSION…"
curl -fsSL "$URL" -o "$TMP/sparkle.tar.xz"
tar -xJf "$TMP/sparkle.tar.xz" -C "$TMP"

mkdir -p "$DEST"
# The tarball's top level is the tools plus the xcframework.
cp -R "$TMP/bin" "$DEST/bin"
chmod +x "$DEST"/bin/* 2>/dev/null || true

echo "Sparkle tools are in $DEST/bin"
