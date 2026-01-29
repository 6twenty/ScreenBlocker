#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building ScreenBlocker..."

# Build the executable
swift build -c release

# Create app bundle structure
APP_DIR="build/ScreenBlocker.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy executable
cp .build/release/ScreenBlocker "$APP_DIR/Contents/MacOS/"

# Copy Info.plist
cp Resources/Info.plist "$APP_DIR/Contents/"

# Copy app icon
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/"

# Ad-hoc sign the app (allows running without Gatekeeper issues on your machine)
codesign --force --deep --sign - "$APP_DIR"

echo ""
echo "Build complete: $APP_DIR"
echo ""
echo "To run: open $APP_DIR"
echo "To install: cp -r $APP_DIR /Applications/"
