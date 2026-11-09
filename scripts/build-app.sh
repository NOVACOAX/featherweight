#!/bin/bash
# Builds build/Featherweight.app (universal), icon included, signed inside-out.
# Usage: scripts/build-app.sh [--version X.Y.Z]   (default: the VERSION file)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION)"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

APP="build/Featherweight.app"
CONTENTS="$APP/Contents"
HELPER_APP="$CONTENTS/Library/LoginItems/Featherweight Helper.app"
HELPER_CONTENTS="$HELPER_APP/Contents"

echo "==> Building universal release binaries"
# One invocation per product: with several --product flags SwiftPM only rebuilds the last one.
for product in FeatherweightApp featherweight FeatherweightHelper; do
    swift build -c release --arch arm64 --arch x86_64 --product "$product"
done
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

for product in FeatherweightApp featherweight FeatherweightHelper; do
    archs="$(lipo -archs "$BIN/$product")"
    if [[ "$archs" != *x86_64* || "$archs" != *arm64* ]]; then
        echo "error: $product is not universal ($archs)" >&2
        exit 1
    fi
done

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Helpers" "$CONTENTS/Resources" \
    "$HELPER_CONTENTS/MacOS" "$HELPER_CONTENTS/Resources"
cp "$BIN/FeatherweightApp" "$CONTENTS/MacOS/Featherweight"
cp "$BIN/featherweight" "$CONTENTS/Helpers/featherweight"
cp "$BIN/FeatherweightHelper" "$HELPER_CONTENTS/MacOS/FeatherweightHelper"
cp Resources/Info-App.plist "$CONTENTS/Info.plist"
cp Resources/Info-Helper.plist "$HELPER_CONTENTS/Info.plist"

# The CLI reads its version from the enclosing app's Info.plist, so both plists carry it.
for plist in "$CONTENTS/Info.plist" "$HELPER_CONTENTS/Info.plist"; do
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$plist"
    plutil -replace CFBundleVersion -string "$VERSION" "$plist"
done

echo "==> Rendering icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift Resources/AppIcon.svg "$ICONSET"
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
cp "$CONTENTS/Resources/AppIcon.icns" "$HELPER_CONTENTS/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

echo "==> Signing"
if security find-certificate -c "Featherweight Self-Signed" >/dev/null 2>&1; then
    IDENTITY="Featherweight Self-Signed"
else
    IDENTITY="-"
    echo "warning: no \"Featherweight Self-Signed\" certificate found; signing ad-hoc." >&2
    echo "         Ad-hoc builds work, but macOS may ask for permissions again after each update." >&2
fi
codesign --force --timestamp=none --sign "$IDENTITY" "$CONTENTS/Helpers/featherweight"
codesign --force --timestamp=none --sign "$IDENTITY" "$HELPER_APP"
codesign --force --timestamp=none --sign "$IDENTITY" "$APP"

echo "==> Verifying"
codesign --verify --deep --strict "$APP"

echo "Built $ROOT/$APP ($(du -sh "$APP" | cut -f1)), version $VERSION, signed with \"$IDENTITY\""
