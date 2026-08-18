#!/bin/bash
set -e

# Get absolute path to root directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Read version
VERSION=$(cat "$ROOT_DIR/VERSION" | tr -d '[:space:]')
echo "Building version $VERSION..."

cd "$ROOT_DIR/MacHost"

# Kill running instance
echo "Stopping running Side Screen..."
pkill -f SideScreen 2>/dev/null || true
sleep 0.5

# Clean old build
echo "Cleaning old build..."
rm -rf .build

# Build fresh (Universal Binary: arm64 + x86_64)
echo "Building macOS Host (arm64)..."
swift build -c release --arch arm64

echo "Building macOS Host (x86_64)..."
swift build -c release --arch x86_64

echo "Creating Universal Binary..."
mkdir -p ".build/release-universal"
lipo -create \
  .build/arm64-apple-macosx/release/SideScreen \
  .build/x86_64-apple-macosx/release/SideScreen \
  -output .build/release-universal/SideScreen

# Create .app bundle
APP_NAME="SideScreen"
APP_DIR="$ROOT_DIR/$APP_NAME.app"

echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy universal binary
cp .build/release-universal/SideScreen "$APP_DIR/Contents/MacOS/"

# No LaunchAgent plist needed for SMAppService.mainApp

# Copy app icon if exists
if [ -f "$ROOT_DIR/MacHost/Resources/AppIcon.icns" ]; then
    cp "$ROOT_DIR/MacHost/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"
    echo "  ✓ App icon copied"
fi

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SideScreen</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.sidescreen.app</string>
    <key>CFBundleName</key>
    <string>Side Screen</string>
    <key>CFBundleDisplayName</key>
    <string>Side Screen</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string><!-- VERSION -->
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string><!-- VERSION -->
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Side Screen needs screen recording access to capture your virtual display and stream it to your Android device.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Side Screen needs Local Network access so your Android tablet can connect to the Mac over WiFi for wireless mode. Without this, only USB-tethered connections work.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_sidescreen._tcp</string>
    </array>
</dict>
</plist>
EOF

# Code sign to prevent Gatekeeper "damaged" error.
#
# Signing identity matters for more than Gatekeeper. An ad-hoc signature has no
# certificate, so TCC identifies the app by its cdhash — a hash of the binary —
# and every rebuild looks like a different app. That is why Accessibility and
# Screen Recording have to be granted again after each build.
#
# Signing with a stable certificate keys those grants to the certificate plus
# bundle ID instead, so they survive rebuilds. A free self-signed certificate
# is enough; see docs/pen-support.md.
SIGN_ID="${SIDESCREEN_SIGN_ID:-SideScreen Local Signing}"
# Deliberately NOT `find-identity -v`: a self-signed certificate reports
# CSSMERR_TP_NOT_TRUSTED and is filtered out by -v, yet it signs perfectly well.
# Trust governs signature *verification*, not creation, and the resulting
# designated requirement (bundle id + leaf certificate hash) is stable across
# rebuilds either way — which is all TCC needs.
SIGN_HASH=$(security find-identity -p codesigning 2>/dev/null \
    | grep -F "$SIGN_ID" | head -1 | awk '{print $2}')
if [ -n "$SIGN_HASH" ]; then
    echo "Code signing (identity: $SIGN_ID)..."
    codesign --force --deep --sign "$SIGN_HASH" \
        --entitlements "$ROOT_DIR/MacHost/SideScreen.entitlements" "$APP_DIR"
    echo "  ✓ App signed — permissions persist across rebuilds"
else
    echo "Code signing (ad-hoc)..."
    codesign --force --deep --sign - \
        --entitlements "$ROOT_DIR/MacHost/SideScreen.entitlements" "$APP_DIR"
    echo "  ✓ App signed (ad-hoc)"
    echo "  ⚠ macOS will ask for Accessibility and Screen Recording again after"
    echo "    every rebuild. Create a '$SIGN_ID' certificate to stop that —"
    echo "    see docs/pen-support.md."
fi

echo ""
echo "Build successful!"
echo ""
echo "App: $ROOT_DIR/$APP_NAME.app"
echo "To run: open $APP_NAME.app"

# Create DMG with Applications symlink
echo ""
echo "Creating DMG..."
DMG_DIR=$(mktemp -d)
cp -R "$APP_DIR" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
DMG_PATH="$ROOT_DIR/SideScreen-${VERSION}-mac-universal.dmg"
hdiutil create -volname "Side Screen" -srcfolder "$DMG_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$DMG_DIR"
echo "DMG: $DMG_PATH"
