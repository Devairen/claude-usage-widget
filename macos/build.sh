#!/bin/bash
set -e

PRODUCT_NAME="Claude Usage"
BINARY_NAME="ClaudeUsage"

echo "Building ${PRODUCT_NAME}..."
swift build -c release 2>&1

BIN_PATH=$(swift build -c release --show-bin-path)
BINARY="${BIN_PATH}/${BINARY_NAME}"

if [ ! -f "$BINARY" ]; then
    echo "Error: binary not found at $BINARY"
    exit 1
fi

# Assemble .app bundle
APP_DIR="dist/${PRODUCT_NAME}.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/${BINARY_NAME}"
cp Resources/Info.plist "$APP_DIR/Contents/"

echo "Built: $APP_DIR"
echo ""
echo "To run:  open \"$APP_DIR\""
echo "First launch: right-click -> Open (bypasses Gatekeeper for unsigned apps)"
