#!/bin/bash
# Build Open Whisperer .app bundle and package as .dmg
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCRIPT_DIR/.build"
APP_NAME="OpenWhisperer"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_NAME="OpenWhisperer-1.4.0"

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

# Step 3: Bundle the TTS hooks (native TTS — no Python scripts to bundle)
cp "$PROJECT_DIR/hooks/tts-hook.sh" "$APP_BUNDLE/Contents/Resources/hooks/"
cp "$PROJECT_DIR/hooks/codex-tts-hook.sh" "$APP_BUNDLE/Contents/Resources/hooks/"
cp "$PROJECT_DIR/hooks/voice-context.sh" "$APP_BUNDLE/Contents/Resources/hooks/"
cp "$PROJECT_DIR/hooks/first-paragraph.sh" "$APP_BUNDLE/Contents/Resources/hooks/"
cp "$PROJECT_DIR/scripts/speak.sh" "$APP_BUNDLE/Contents/Resources/scripts/"

# Make scripts executable
chmod +x "$APP_BUNDLE/Contents/Resources/hooks/tts-hook.sh"
chmod +x "$APP_BUNDLE/Contents/Resources/hooks/codex-tts-hook.sh"
chmod +x "$APP_BUNDLE/Contents/Resources/hooks/voice-context.sh"
chmod +x "$APP_BUNDLE/Contents/Resources/hooks/first-paragraph.sh"
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

# Step 6: Ad-hoc code sign
echo "Code signing..."
codesign --force --deep --sign - "$APP_BUNDLE"

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

echo ""
echo "=== Done ==="
echo "DMG: $DMG_OUTPUT"
echo "App: $APP_BUNDLE"
echo ""
echo "To install: open the DMG and drag OpenWhisperer to Applications"
