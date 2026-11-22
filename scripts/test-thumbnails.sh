#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/.build/thumbnail-checks"
mkdir -p "$TEST_DIR"
# 仅编译缩略图实现、诊断与测试夹具，不构建或启动 WindowPilot app。
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
    "$PROJECT_DIR/Sources/WindowPilot/Diagnostics.swift" \
    "$PROJECT_DIR/Sources/WindowPilot/ThumbnailStore.swift" \
    "$PROJECT_DIR/Tests/ThumbnailTests/ThumbnailStoreTests.swift" \
    -o "$TEST_DIR/check-thumbnails"
"$TEST_DIR/check-thumbnails"
