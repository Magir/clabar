#!/bin/sh
# Clabar installer.
# Files downloaded with curl carry no com.apple.quarantine attribute, so the
# app opens without Gatekeeper friction (browser-downloaded zips do not).
set -e

REPO="Magir/clabar"
DEST="${CLABAR_INSTALL_DIR:-/Applications}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading the latest Clabar release…"
curl -fsSL -o "$TMP/Clabar.zip" "https://github.com/$REPO/releases/latest/download/Clabar.zip"
ditto -x -k "$TMP/Clabar.zip" "$TMP"

if [ "$DEST" = "/Applications" ]; then
  osascript -e 'tell application "Clabar" to quit' >/dev/null 2>&1 || true
  sleep 1
fi
rm -rf "$DEST/Clabar.app"
mv "$TMP/Clabar.app" "$DEST/"
# Belt and suspenders: harmless when the attribute is absent.
xattr -dr com.apple.quarantine "$DEST/Clabar.app" 2>/dev/null || true

echo "Installed: $DEST/Clabar.app"
if [ "$DEST" = "/Applications" ]; then
  open "$DEST/Clabar.app"
fi
