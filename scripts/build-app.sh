#!/bin/bash
# Builds "Huddle Leveler.app" into build/, signs it, and with --install copies
# it to ~/Applications.
#
# It signs with an Apple Development certificate when one is in the keychain
# (override with SIGN_IDENTITY=...). macOS remembers the audio-recording
# permission per signing identity, so a stable certificate keeps that
# permission across rebuilds; an ad-hoc signature would ask again each time.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product HuddleLeveler

APP="build/Huddle Leveler.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/HuddleLeveler "$APP/Contents/MacOS/HuddleLeveler"
cp Sources/HuddleLevelerApp/Info.plist "$APP/Contents/Info.plist"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
if [ -z "$IDENTITY" ]; then
    echo "No Apple Development certificate found; signing ad hoc." >&2
    IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --verbose=1 "$APP"
echo "Built $APP (signed by $IDENTITY)"

if [ "${1:-}" = "--install" ]; then
    DEST="$HOME/Applications/Huddle Leveler.app"
    mkdir -p "$HOME/Applications"
    pkill -x HuddleLeveler 2>/dev/null && sleep 1 || true
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    echo "Installed to $DEST"
fi
