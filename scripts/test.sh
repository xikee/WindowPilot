#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/.build/checks"
TARGET="$(uname -m)-apple-macosx13.0"
mkdir -p "$TEST_DIR"
xcrun swiftc -target "$TARGET" -parse-as-library -emit-library -static -emit-module -module-name SwitchCore \
    "$PROJECT_DIR"/Sources/SwitchCore/*.swift -emit-module-path "$TEST_DIR/SwitchCore.swiftmodule" -o "$TEST_DIR/libSwitchCore.a"
xcrun swiftc -target "$TARGET" -parse-as-library -I "$TEST_DIR" -L "$TEST_DIR" -lSwitchCore \
    "$PROJECT_DIR/Tests/SwitchCoreTests/Scenarios.swift" "$PROJECT_DIR/scripts/check-core.swift" -o "$TEST_DIR/check-core"
"$TEST_DIR/check-core"
xcrun swiftc -target "$TARGET" -parse-as-library -I "$TEST_DIR" -L "$TEST_DIR" -lSwitchCore \
    "$PROJECT_DIR/Sources/WindowPilot/WindowService.swift" \
    "$PROJECT_DIR/Sources/WindowPilot/WindowActivator.swift" \
    "$PROJECT_DIR/Sources/WindowPilot/Diagnostics.swift" \
    "$PROJECT_DIR/Tests/SystemTests/ActivationScenarios.swift" -o "$TEST_DIR/check-activation"
"$TEST_DIR/check-activation"
bash "$PROJECT_DIR/scripts/test-thumbnails.sh"
