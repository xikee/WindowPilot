#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
CONFIGURATION="${1:-release}"
if [[ "$CONFIGURATION" != "release" && "$CONFIGURATION" != "debug" ]]; then
    echo "用法：bash scripts/build.sh [release|debug]" >&2
    exit 1
fi
BIN_DIR="$PROJECT_DIR/.build/native/$CONFIGURATION"
mkdir -p "$BIN_DIR"
TARGET="$(uname -m)-apple-macosx13.0"
OPTIMIZATION="-O"
if [[ "$CONFIGURATION" == "debug" ]]; then OPTIMIZATION="-Onone"; fi
xcrun swiftc -target "$TARGET" "$OPTIMIZATION" -parse-as-library -emit-library -static -emit-module \
    -module-name SwitchCore "$PROJECT_DIR"/Sources/SwitchCore/*.swift \
    -emit-module-path "$BIN_DIR/SwitchCore.swiftmodule" -o "$BIN_DIR/libSwitchCore.a"
xcrun swiftc -target "$TARGET" "$OPTIMIZATION" -I "$BIN_DIR" -L "$BIN_DIR" -lSwitchCore \
    "$PROJECT_DIR"/Sources/WindowPilot/*.swift -o "$BIN_DIR/WindowPilot"
APP_DIR="${WINDOWPILOT_APP_DIR:-$PROJECT_DIR/dist/瞬切.app}"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/WindowPilot" "$APP_DIR/Contents/MacOS/WindowPilot"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
xcrun swiftc "$PROJECT_DIR/scripts/make-icon.swift" -o "$BIN_DIR/make-icon"
"$BIN_DIR/make-icon" "$PROJECT_DIR/.build/AppIcon.iconset"
iconutil -c icns "$PROJECT_DIR/.build/AppIcon.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier local.windowpilot.app "$APP_DIR"
echo "构建完成：$APP_DIR"
