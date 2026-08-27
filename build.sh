#!/bin/bash
# Build "BlueBird DocuCam.app".
#
#   ./build.sh          Universal build, ad-hoc signed (local / testing).
#   ./build.sh --sign   Universal build, Developer ID signed + notarized + stapled,
#                       packaged as BlueBird-DocuCam.dmg (+ .zip). Ready to distribute
#                       — installs with no Gatekeeper prompt.
#
# --sign uses these (override via env or a .env file beside this script):
#   TEAM_ID             default XK6QP975ZQ  (the Developer ID Application team)
#   NOTARYTOOL_PROFILE  default "axe"       (shared notarytool keychain profile;
#                                            account-wide, works for any app on the team)
# Or set APPLE_ID + APP_PASSWORD instead of NOTARYTOOL_PROFILE.
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"

[[ -f "$HERE/.env" ]] && set -a && source "$HERE/.env" && set +a

APP_DISPLAY="BlueBird DocuCam"              # .app / Finder / DMG volume name
EXECNAME="BlueBirdDocuCam"                  # binary name (no spaces)
BUNDLE_ID="com.emerytech.BlueBirdDocuCam"
MIN_MACOS="13.0"
TEAM_ID="${TEAM_ID:-XK6QP975ZQ}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-axe}"
APPLE_ID="${APPLE_ID:-}"
APP_PASSWORD="${APP_PASSWORD:-}"

SIGN=false
for a in "$@"; do [[ "$a" == "--sign" ]] && SIGN=true; done

BUILD="build"
APP="$BUILD/$APP_DISPLAY.app"
DMG="$HERE/BlueBird-DocuCam.dmg"
ZIP="$HERE/BlueBird-DocuCam.zip"

# ── Build (universal) ──────────────────────────────────────────────────────────
rm -rf "$BUILD"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling arm64…"
swiftc -O -target "arm64-apple-macos$MIN_MACOS" main.swift -o "$BUILD/$EXECNAME-arm64"
if swiftc -O -target "x86_64-apple-macos$MIN_MACOS" main.swift -o "$BUILD/$EXECNAME-x86_64" 2>/dev/null; then
    echo "Compiling x86_64… ok — universal binary"
    lipo -create -output "$APP/Contents/MacOS/$EXECNAME" "$BUILD/$EXECNAME-arm64" "$BUILD/$EXECNAME-x86_64"
else
    echo "x86_64 slice failed — arm64-only (Apple Silicon Macs only)"
    cp "$BUILD/$EXECNAME-arm64" "$APP/Contents/MacOS/$EXECNAME"
fi
cp Info.plist "$APP/Contents/Info.plist"

# ── Ad-hoc path (dev) ──────────────────────────────────────────────────────────
if ! $SIGN; then
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
    echo "Built (ad-hoc): $APP"
    echo "For a distributable installer:  ./build.sh --sign"
    exit 0
fi

# ── Notarization helper ────────────────────────────────────────────────────────
notarize() {  # $1 = path to .zip or .dmg
    if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
        xcrun notarytool submit "$1" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
    elif [[ -n "$APPLE_ID" && -n "$APP_PASSWORD" ]]; then
        xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" --wait
    else
        echo "✗ Set NOTARYTOOL_PROFILE or APPLE_ID+APP_PASSWORD to notarize." >&2; exit 1
    fi
}

# ── Developer ID sign ──────────────────────────────────────────────────────────
SIGN_IDENTITY="Developer ID Application: Taylor Emery ($TEAM_ID)"
echo "→ Signing: $SIGN_IDENTITY"
codesign --force --options runtime --timestamp \
         --entitlements "$HERE/entitlements.plist" \
         --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "   signature OK"

# ── Notarize + staple the app ──────────────────────────────────────────────────
echo "→ Notarizing app (…~1–2 min)…"
NT="$(mktemp -d)"
ditto -c -k --keepParent "$APP" "$NT/app.zip"
notarize "$NT/app.zip"
rm -rf "$NT"
# Clear xattrs before stapling — prevents ditto from re-embedding AppleDouble ._
# sidecars in the Homebrew-style zip (which a plain unzip would materialize as
# files and break the seal). The signature + ticket are files in the bundle, not
# xattrs, so this is safe; the verify gate below re-checks the seal + Gatekeeper.
xattr -cr "$APP"
xcrun stapler staple "$APP"
codesign --verify --strict "$APP"

# ── Zip artifact (Homebrew-safe: no ._ sidecars) ───────────────────────────────
find "$APP" -name '._*' -delete 2>/dev/null || true
ditto --noextattr --norsrc -c -k --keepParent "$APP" "$ZIP"
if unzip -l "$ZIP" | grep -q '/\._'; then echo "✗ ABORT: zip has ._ sidecars." >&2; exit 1; fi

# ── DMG (Applications symlink for drag-install) ────────────────────────────────
echo "→ Building DMG…"
DMGTMP="$(mktemp -d)"
cp -R "$APP" "$DMGTMP/"
ln -s /Applications "$DMGTMP/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_DISPLAY" -srcfolder "$DMGTMP" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMGTMP"

# ── Notarize + staple the DMG ──────────────────────────────────────────────────
echo "→ Notarizing DMG (…~1–2 min)…"
notarize "$DMG"
xcrun stapler staple "$DMG"

# ── Verify gates ───────────────────────────────────────────────────────────────
echo "→ Verifying…"
# App: spctl is the authoritative Gatekeeper check for an executable bundle.
spctl -a -t exec -vv "$APP" 2>&1 | grep -E 'accepted|origin=' || { echo "✗ app rejected by Gatekeeper" >&2; exit 1; }
xcrun stapler validate "$APP" || { echo "✗ app not stapled" >&2; exit 1; }
# DMG: spctl's disk-image assessment is unreliable on recent macOS, so the
# authoritative gate here is stapler (ticket attached + valid). notarytool
# already reported "Accepted" above.
xcrun stapler validate "$DMG" || { echo "✗ dmg not stapled" >&2; exit 1; }
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | grep -E 'accepted|rejected' || true  # informational only

echo ""
echo "✓ Signed, notarized, stapled — ready to distribute:"
echo "   $DMG"
echo "   $ZIP"