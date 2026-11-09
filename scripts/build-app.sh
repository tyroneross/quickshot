#!/bin/bash
# Builds QuickShot.app from the Swift package.
#
#   scripts/build-app.sh              build into build/QuickShot.app
#   scripts/build-app.sh --install    also copy it to /Applications
#
# Signing is ad-hoc by default, which never touches the Keychain. macOS ties a
# Screen Recording grant to the exact build of an ad-hoc app, so each rebuild
# must be granted again. To keep the grant across rebuilds, sign with your own
# identity:  QUICKSHOT_CODESIGN_IDENTITY="Developer ID Application: ..." scripts/build-app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/QuickShot.app"
IDENTITY="${QUICKSHOT_CODESIGN_IDENTITY:--}"
BUNDLE_ID="ai.rosslabs.quickshot"

cd "$ROOT"
swift build -c release
BINARY="$(swift build -c release --show-bin-path)/QuickShot"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/QuickShot"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/QuickShot.app"
    if pgrep -xq QuickShot; then
        echo "QuickShot is running. Quit it, then run this again." >&2
        exit 1
    fi
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    echo "Installed $DEST"
fi
