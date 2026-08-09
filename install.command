#!/bin/bash
# Build PR Review.app and install it into ~/Applications, replacing any
# previously installed copy. Double-clickable (or run from a terminal).
set -euo pipefail

# Require only Xcode Command Line Tools — full Xcode is NOT needed.
# Install them with: xcode-select --install
if ! command -v swift >/dev/null 2>&1; then
  echo "Error: 'swift' not found."
  echo "Install Xcode Command Line Tools (no full Xcode needed):"
  echo "  xcode-select --install"
  exit 1
fi

# Ensure the active developer directory is set (CLT or Xcode either works).
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Error: No active developer directory found."
  echo "Run: xcode-select --install"
  exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="PR Review.app"
DEST_DIR="$HOME/Applications"
DEST_APP="$DEST_DIR/$APP_NAME"

echo "Building PR Review (Release)…"
bash "$ROOT/scripts/build-app" release

# A running copy keeps its old executable in memory. Quit it before replacing
# the bundle, then use `open -n` below so macOS cannot simply focus that stale
# process instead of launching the newly installed build.
if osascript -e 'if application "PR Review" is running then tell application "PR Review" to quit' >/dev/null 2>&1; then
  sleep 0.5
fi

readonly built_app="$ROOT/build/$APP_NAME"
if [ ! -d "$built_app" ]; then
  echo "Error: Build succeeded but app bundle not found at: $built_app"
  exit 1
fi

echo "Installing to ${DEST_APP}…"
mkdir -p "$DEST_DIR"
rm -rf "$DEST_APP"
mv "$built_app" "$DEST_APP"

echo ""
echo "Installed: $DEST_APP"
echo "Launch:    open -n \"$DEST_APP\""
open -n "$DEST_APP"
