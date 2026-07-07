#!/bin/bash
# Build Open Whisperer .app bundle and package as .dmg
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCRIPT_DIR/.build"
APP_NAME="OpenWhisperer"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
# Version is single-sourced from Info.plist (CFBundleShortVersionString) —
# bump it there (both keys) and the DMG name follows automatically.
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$SCRIPT_DIR/Resources/Info.plist")
DMG_NAME="OpenWhisperer-$VERSION"

echo "=== Building Open Whisperer ==="

# Step 1: Build Swift binary
echo "Compiling Swift..."
cd "$SCRIPT_DIR"
swift build -c release 2>&1

BINARY="$SCRIPT_DIR/.build/release/OpenWhisperer"
if [ ! -f "$BINARY" ]; then
    echo "Error: Build failed — binary not found"
    exit 1
fi

# Step 2: Create .app bundle structure
echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/hooks"
mkdir -p "$APP_BUNDLE/Contents/Resources/scripts"
mkdir -p "$APP_BUNDLE/Contents/Resources/pi"

# Copy binary
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/OpenWhisperer"

# Copy SwiftPM resource bundles (e.g. swift-transformers Hub, swift-crypto) so
# `Bundle.module` resolves them at runtime. WhisperKit pulls these in; without them
# the packaged .app crashes on first model load. They are looked up via
# Bundle.main.resourceURL (= Contents/Resources). Statically-linked Swift code means
# no dylibs to copy — only these bundles.
for bundle in "$SCRIPT_DIR/.build/release/"*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
done

# Copy Info.plist, icon, and fonts
cp "$SCRIPT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/"
cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
cp "$SCRIPT_DIR/Resources/Outfit-VariableFont_wght.ttf" "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
cp "$SCRIPT_DIR/Resources/Fraunces.ttf" "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true

# Step 3: Bundle the voice hooks (Claude/Codex + Antigravity), their shared logic, speak.sh,
# and the Pi extension
cp "$PROJECT_DIR/hooks/voice-context.sh" "$APP_BUNDLE/Contents/Resources/hooks/"
cp "$PROJECT_DIR/hooks/voice-shared.sh" "$APP_BUNDLE/Contents/Resources/hooks/"
cp "$PROJECT_DIR/hooks/agy-previnvocation.sh" "$APP_BUNDLE/Contents/Resources/hooks/"
cp "$PROJECT_DIR/scripts/speak.sh" "$APP_BUNDLE/Contents/Resources/scripts/"
cp "$PROJECT_DIR/pi/openwhisperer.ts" "$APP_BUNDLE/Contents/Resources/pi/"

# Make scripts executable
chmod +x "$APP_BUNDLE/Contents/Resources/hooks/voice-context.sh"
chmod +x "$APP_BUNDLE/Contents/Resources/hooks/voice-shared.sh"
chmod +x "$APP_BUNDLE/Contents/Resources/hooks/agy-previnvocation.sh"
chmod +x "$APP_BUNDLE/Contents/Resources/scripts/speak.sh"

# Step 4: Bundle jq binary (detect architecture) — the hooks use jq for JSON
ARCH=$(uname -m)
echo "Bundling jq..."
JQ_PATH=$(which jq 2>/dev/null || echo "")
if [ -z "$JQ_PATH" ]; then
    if [ "$ARCH" = "arm64" ]; then
        JQ_URL="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-arm64"
    else
        JQ_URL="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-amd64"
    fi
    echo "Downloading jq for $ARCH..."
    curl -LsS "$JQ_URL" -o "$APP_BUNDLE/Contents/Resources/jq"
else
    cp "$JQ_PATH" "$APP_BUNDLE/Contents/Resources/jq"
fi
chmod +x "$APP_BUNDLE/Contents/Resources/jq"

# Step 6: Code sign
# The signing identity is configurable via OW_SIGN_IDENTITY so the same script
# serves three cases:
#   unset / "-"                    → ad-hoc (default). Portable, but the cdhash
#                                    changes every build, so macOS drops the
#                                    app's Accessibility + Microphone TCC grants
#                                    on every rebuild.
#   "OpenWhisperer Dev"            → a stable local self-signed cert. TCC keys
#                                    grants on the signature's designated
#                                    requirement (constant across rebuilds), so
#                                    permissions persist. The fix for local dev.
#   "Developer ID Application: …"  → release signing. Pair with OW_NOTARIZE=1
#                                    (and OW_NOTARIZE_PROFILE) to produce a
#                                    hardened-runtime, notarized, stapled DMG
#                                    that runs on other Macs without Gatekeeper
#                                    warnings. Requires a paid Apple Developer
#                                    account; left to whoever ships releases.
SIGN_IDENTITY="${OW_SIGN_IDENTITY:--}"
echo "Code signing with identity: $SIGN_IDENTITY"

if [ -n "$OW_NOTARIZE" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    # Release path: hardened runtime + entitlements + secure timestamp.
    # Sign the bundled jq (nested Mach-O) first — notarization rejects unsigned
    # or un-hardened nested code — then the outer bundle.
    ENTITLEMENTS="$SCRIPT_DIR/Resources/OpenWhisperer.entitlements"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Resources/jq"
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    # Ad-hoc or stable-dev local build: plain signature, no hardened runtime
    # (not needed to run locally or to keep TCC grants; only notarization needs it).
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
fi

echo ""
echo "App bundle created: $APP_BUNDLE"

# Step 7: Create DMG
echo "Creating DMG..."
DMG_TMP="$BUILD_DIR/dmg-staging"
DMG_OUTPUT="$BUILD_DIR/$DMG_NAME.dmg"
rm -rf "$DMG_TMP" "$DMG_OUTPUT"
mkdir -p "$DMG_TMP"

cp -R "$APP_BUNDLE" "$DMG_TMP/"

# Add Applications symlink for drag-to-install
ln -s /Applications "$DMG_TMP/Applications"

hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_TMP" \
    -ov -format UDZO \
    "$DMG_OUTPUT"

rm -rf "$DMG_TMP"

# Step 8: Notarize + staple (release only).
# Gated on OW_NOTARIZE so local/ad-hoc builds skip it entirely. Requires a paid
# Apple Developer account and a stored notarytool credential profile, created once:
#   xcrun notarytool store-credentials "<profile>" \
#       --apple-id <id> --team-id <team> --password <app-specific-password>
# then build with: OW_SIGN_IDENTITY="Developer ID Application: …" \
#                  OW_NOTARIZE=1 OW_NOTARIZE_PROFILE="<profile>" ./build-dmg.sh
# Untested locally (no Developer ID account here); verify on the release machine.
if [ -n "$OW_NOTARIZE" ]; then
    PROFILE="${OW_NOTARIZE_PROFILE:?OW_NOTARIZE set but OW_NOTARIZE_PROFILE is empty}"
    echo "Notarizing $DMG_OUTPUT (profile: $PROFILE)..."
    xcrun notarytool submit "$DMG_OUTPUT" --keychain-profile "$PROFILE" --wait
    echo "Stapling ticket..."
    xcrun stapler staple "$DMG_OUTPUT"
    xcrun stapler validate "$DMG_OUTPUT"
fi

echo ""
echo "=== Done ==="
echo "DMG: $DMG_OUTPUT"
echo "App: $APP_BUNDLE"
echo ""
echo "To install: open the DMG and drag OpenWhisperer to Applications"
