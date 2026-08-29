#!/bin/bash
# Build "BlueBird DocuCam.app".
#
#   ./build.sh          Universal build, ad-hoc signed (local / testing).
#   ./build.sh --sign   Universal build, Developer ID signed + notarized + stapled,
#                       packaged as BlueBird-DocuCam.dmg (+ .zip). Ready to distribute
#                       — installs with no Gatekeeper prompt.
#   ./build.sh --mas    Mac App Store build: compiles with -D APP_STORE (sandbox +
#                       StoreKit subscription gate, no Ko-fi / self-updater). With the
#                       MAS_* env vars set it produces an uploadable, signed .pkg;
#                       without them it ad-hoc sandbox-signs for local verification.
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
MAS=false
SWIFT_FLAGS=""
for a in "$@"; do
    [[ "$a" == "--sign" ]] && SIGN=true
    [[ "$a" == "--mas"  ]] && MAS=true
done
$MAS && SWIFT_FLAGS="-D APP_STORE"

BUILD="build"
APP="$BUILD/$APP_DISPLAY.app"
DMG="$HERE/BlueBird-DocuCam.dmg"
ZIP="$HERE/BlueBird-DocuCam.zip"

# ── Build (universal) ──────────────────────────────────────────────────────────
rm -rf "$BUILD"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling arm64…${SWIFT_FLAGS:+ ($SWIFT_FLAGS)}"
swiftc -O $SWIFT_FLAGS -target "arm64-apple-macos$MIN_MACOS" main.swift -o "$BUILD/$EXECNAME-arm64"
if swiftc -O $SWIFT_FLAGS -target "x86_64-apple-macos$MIN_MACOS" main.swift -o "$BUILD/$EXECNAME-x86_64" 2>/dev/null; then
    echo "Compiling x86_64… ok — universal binary"
    lipo -create -output "$APP/Contents/MacOS/$EXECNAME" "$BUILD/$EXECNAME-arm64" "$BUILD/$EXECNAME-x86_64"
else
    echo "x86_64 slice failed — arm64-only (Apple Silicon Macs only)"
    cp "$BUILD/$EXECNAME-arm64" "$APP/Contents/MacOS/$EXECNAME"
fi
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# ── Mac App Store path ─────────────────────────────────────────────────────────
if $MAS; then
    PKG="$HERE/BlueBird-DocuCam-MAS.pkg"
    # The MAS signing assets (created 2026-08-28; see docs/APP_STORE.md). Override any
    # of these via env or .env. The certs are the legacy Mac-specific distribution
    # types (NOT "Apple Distribution", so they don't touch the EAS cert limit):
    MAS_APP_CERT="${MAS_APP_CERT:-3rd Party Mac Developer Application: Taylor Emery ($TEAM_ID)}"
    MAS_INSTALLER_CERT="${MAS_INSTALLER_CERT:-3rd Party Mac Developer Installer: Taylor Emery ($TEAM_ID)}"
    MAS_PROFILE="${MAS_PROFILE:-$HOME/.config/bluebird/docucam-mas/BlueBird_DocuCam_Mac_App_Store.provisionprofile}"
    if [[ -e "$MAS_PROFILE" ]] \
       && security find-identity -v -p codesigning | grep -qF "$MAS_APP_CERT" \
       && security find-identity -v -p basic       | grep -qF "$MAS_INSTALLER_CERT"; then
        cp "$MAS_PROFILE" "$APP/Contents/embedded.provisionprofile"
        # Strip com.apple.quarantine (and any other xattrs) BEFORE signing — the
        # downloaded .provisionprofile carries it, which App Store upload rejects
        # (ITMS-91109). Do it before codesign so the seal covers clean files.
        xattr -cr "$APP"
        codesign --force --timestamp \
                 --entitlements "$HERE/entitlements-mas.plist" \
                 --sign "$MAS_APP_CERT" "$APP"
        codesign --verify --strict "$APP"
        productbuild --component "$APP" /Applications --sign "$MAS_INSTALLER_CERT" "$PKG"
        echo ""
        echo "✓ Mac App Store package: $PKG"
        echo "  Upload:  xcrun altool --upload-app -f \"$PKG\" -t macos \\"
        echo "                 --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>"
        echo "  (or open it with Transporter.app)"
    else
        # Signing assets missing — ad-hoc sandbox sign so you can verify it builds
        # and launches sandboxed. StoreKit can't load products without the real
        # App Store, so the paywall shows "Loading plans…" in this local build.
        codesign --force --sign - --identifier "$BUNDLE_ID" \
                 --entitlements "$HERE/entitlements-mas.plist" "$APP"
        echo ""
        echo "Built (ad-hoc, sandboxed, APP_STORE): $APP"
        echo "This is a LOCAL-VERIFY build only (MAS cert or profile not found)."
        echo "Expected profile: $MAS_PROFILE"
        echo "Expected certs:   $MAS_APP_CERT / $MAS_INSTALLER_CERT"
    fi
    exit 0
fi

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