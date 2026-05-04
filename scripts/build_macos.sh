#!/bin/bash
set -euo pipefail

# MinuteModem macOS build script
# Run from the repo root: ./scripts/build_macos.sh [version]

VERSION="${1:-0.1.0}"
ARCH="$(uname -m)"
RELEASE_NAME="minutemodem_station"
APP_NAME="MinuteModem"
BUILD_DIR="build/macos"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

echo "==> Building $APP_NAME $VERSION for $ARCH"

# Step 1: OTP release
echo "==> Building release..."
MIX_ENV=prod mix release "$RELEASE_NAME" --overwrite

# Step 2: Assemble .app bundle
echo "==> Assembling .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy release into bundle
cp -R "_build/prod/rel/$RELEASE_NAME/" "$APP_DIR/Contents/Resources/rel/"

# Copy app metadata
cp "macos/Info.plist" "$APP_DIR/Contents/"

# Stamp version into Info.plist
sed -i '' "s/0\.1\.0/$VERSION/g" "$APP_DIR/Contents/Info.plist"

# Copy icon if it exists
if [ -f "macos/minutemodem.icns" ]; then
  cp "macos/minutemodem.icns" "$APP_DIR/Contents/Resources/"
fi

# Copy launcher and make executable
cp "macos/launcher.sh" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

# Ensure all release binaries are executable
find "$APP_DIR/Contents/Resources/rel/bin" -type f -exec chmod +x {} \;
find "$APP_DIR/Contents/Resources/rel/erts-"*/bin -type f -exec chmod +x {} \; 2>/dev/null || true

echo "==> Built: $APP_DIR"
echo "    Test with: open \"$APP_DIR\""

# Step 3: DMG (optional, requires create-dmg)
if command -v create-dmg &> /dev/null; then
  echo "==> Creating DMG..."
  DMG_NAME="MinuteModem-${VERSION}-${ARCH}.dmg"
  rm -f "build/$DMG_NAME"

  create-dmg \
    --volname "MinuteModem $VERSION" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 100 \
    --icon "MinuteModem.app" 180 170 \
    --app-drop-link 480 170 \
    --hide-extension "MinuteModem.app" \
    "build/$DMG_NAME" \
    "$APP_DIR" || true  # create-dmg returns non-zero if no icon set

  echo "==> DMG: build/$DMG_NAME"
else
  echo "==> Skipping DMG (install create-dmg: brew install create-dmg)"
fi

echo "==> Done!"
