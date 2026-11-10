#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/.build/checks"
mkdir -p "$TEST_DIR"
xcrun swiftc -parse-as-library -emit-library -static -emit-module -module-name SwitchCore \
    "$PROJECT_DIR"/Sources/SwitchCore/*.swift -emit-module-path "$TEST_DIR/SwitchCore.swiftmodule" -o "$TEST_DIR/libSwitchCore.a"
xcrun swiftc -parse-as-library -I "$TEST_DIR" -L "$TEST_DIR" -lSwitchCore \
    "$PROJECT_DIR/Tests/SwitchCoreTests/Scenarios.swift" "$PROJECT_DIR/scripts/check-core.swift" -o "$TEST_DIR/check-core"
"$TEST_DIR/check-core"
