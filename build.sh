#!/bin/bash
# Build "BlueBird Doc Camera.app" — a universal (arm64 + x86_64), ad-hoc-signed macOS app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP_DISPLAY="BlueBird Doc Camera"          # .app bundle / Finder name
EXECNAME="BlueBirdDocCamera"               # binary name (no spaces)
BUNDLE_ID="com.emerytech.BlueBirdDocCamera"
MIN_MACOS="13.0"
BUILD="build"
APP="$BUILD/$APP_DISPLAY.app"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling arm64…"
swiftc -O -target "arm64-apple-macos$MIN_MACOS" main.swift -o "$BUILD/$EXECNAME-arm64"

if swiftc -O -target "x86_64-apple-macos$MIN_MACOS" main.swift -o "$BUILD/$EXECNAME-x86_64" 2>/dev/null; then
    echo "Compiling x86_64… ok — creating universal binary"
    lipo -create -output "$APP/Contents/MacOS/$EXECNAME" "$BUILD/$EXECNAME-arm64" "$BUILD/$EXECNAME-x86_64"
else
    echo "x86_64 slice failed to build — shipping arm64-only (Apple Silicon Macs only)"
    cp "$BUILD/$EXECNAME-arm64" "$APP/Contents/MacOS/$EXECNAME"
fi

cp Info.plist "$APP/Contents/Info.plist"

echo "Signing (ad-hoc)…"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo
echo "Built: $APP"
lipo -info "$APP/Contents/MacOS/$EXECNAME"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature' || true
