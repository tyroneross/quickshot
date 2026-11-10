#!/bin/bash
# Builds QuickShot.app from the Swift package.
#
#   scripts/build-app.sh              build into build/QuickShot.app
#   scripts/build-app.sh --install    also copy it to /Applications
#                                     (QUICKSHOT_INSTALL_DIR overrides the folder)
#
# Signing is ad-hoc by default, which never touches the Keychain. macOS ties a
# Screen Recording grant to the exact build of an ad-hoc app, so each rebuild
# must be granted again. To keep the grant across rebuilds, sign with your own
# identity:  QUICKSHOT_CODESIGN_IDENTITY="Developer ID Application: ..." scripts/build-app.sh
#
# A Developer ID build is signed with the hardened runtime and a timestamp, as
# notarization requires. To notarize and staple it as well, name your
# notarytool Keychain profile:  QUICKSHOT_NOTARY_PROFILE=<profile> ...
# (or an App Store Connect API key: QUICKSHOT_NOTARY_KEY, _KEY_ID, _ISSUER).
# Credentials are never read from or written to this repository.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/QuickShot.app"
IDENTITY="${QUICKSHOT_CODESIGN_IDENTITY:--}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$ROOT/Resources/Info.plist")"

cd "$ROOT"
swift build -c release
BINARY="$(swift build -c release --show-bin-path)/QuickShot"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/QuickShot"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

SIGN_FLAGS=(--force --sign "$IDENTITY" --identifier "$BUNDLE_ID")
if [[ "$IDENTITY" != "-" ]]; then
    # Notarization needs the hardened runtime, a secure timestamp and the
    # entitlements the app relies on (the microphone, for Demo recordings).
    SIGN_FLAGS+=(--options runtime --timestamp --entitlements "$ROOT/Resources/QuickShot.entitlements")
fi
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"

NOTARY=()
if [[ -n "${QUICKSHOT_NOTARY_PROFILE:-}" ]]; then
    NOTARY=(--keychain-profile "$QUICKSHOT_NOTARY_PROFILE")
elif [[ -n "${QUICKSHOT_NOTARY_KEY:-}${QUICKSHOT_NOTARY_KEY_ID:-}${QUICKSHOT_NOTARY_ISSUER:-}" ]]; then
    : "${QUICKSHOT_NOTARY_KEY:?set QUICKSHOT_NOTARY_KEY, _KEY_ID and _ISSUER together}"
    : "${QUICKSHOT_NOTARY_KEY_ID:?set QUICKSHOT_NOTARY_KEY, _KEY_ID and _ISSUER together}"
    : "${QUICKSHOT_NOTARY_ISSUER:?set QUICKSHOT_NOTARY_KEY, _KEY_ID and _ISSUER together}"
    NOTARY=(--key "$QUICKSHOT_NOTARY_KEY" --key-id "$QUICKSHOT_NOTARY_KEY_ID" --issuer "$QUICKSHOT_NOTARY_ISSUER")
fi
if [[ ${#NOTARY[@]} -gt 0 ]]; then
    [[ "$IDENTITY" == Developer\ ID* ]] || { echo "notarization needs a Developer ID Application identity" >&2; exit 1; }
    ZIP="$ROOT/build/QuickShot-notarize.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" "${NOTARY[@]}" --wait
    rm -f "$ZIP"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute "$APP"
    echo "Notarized and stapled $APP"
fi

if [[ "${1:-}" == "--install" ]]; then
    DEST="${QUICKSHOT_INSTALL_DIR:-/Applications}/QuickShot.app"
    if pgrep -xq QuickShot; then
        echo "QuickShot is running. Quit it, then run this again." >&2
        exit 1
    fi
    # Stage the new copy first, so a failed copy never costs the working app.
    STAGED="$DEST.installing"
    PREVIOUS="$DEST.previous"
    # An earlier install interrupted mid-swap left the working app parked as
    # .previous. Put it back before doing anything else.
    if [[ ! -e "$DEST" && -e "$PREVIOUS" ]]; then mv "$PREVIOUS" "$DEST"; fi
    rm -rf "$STAGED"
    cp -R "$APP" "$STAGED"
    codesign --verify --strict "$STAGED"
    # Only now, with a verified replacement staged, is an old parked copy redundant.
    rm -rf "$PREVIOUS"
    if [[ -e "$DEST" ]]; then mv "$DEST" "$PREVIOUS"; fi
    if ! mv "$STAGED" "$DEST"; then
        if [[ -e "$PREVIOUS" ]]; then mv "$PREVIOUS" "$DEST"; fi
        echo "Install failed; the previous copy was put back." >&2
        exit 1
    fi
    rm -rf "$PREVIOUS"
    echo "Installed $DEST"
fi
