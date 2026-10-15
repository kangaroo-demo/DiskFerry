#!/bin/bash
# Test FSKit value-object validation without mounting or opening any device.
set -euo pipefail
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="$TASK_ROOT/.build/fskit-adapter-tests"
TASK_FRAMEWORKS="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer/Library/Frameworks"
TASK_TEST_LIB="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer/usr/lib"
TASK_TEST_PRIVATE_FRAMEWORKS="${TASK_FRAMEWORKS%/Frameworks}/PrivateFrameworks"
mkdir -p "$TASK_OUTPUT"
xcrun swiftc -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macos26.4" \
    -F "$TASK_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TASK_FRAMEWORKS" \
    -I "$TASK_TEST_LIB" -L "$TASK_TEST_LIB" -Xlinker -rpath -Xlinker "$TASK_TEST_LIB" \
    -Xlinker -rpath -Xlinker "$TASK_TEST_PRIVATE_FRAMEWORKS" \
    "$TASK_ROOT/Extensions/DiskFerryNTFS/NTFSValidation.swift" \
    "$TASK_ROOT/Tests/FSKitAdapterTests/main.swift" -o "$TASK_OUTPUT/validation-tests"
"$TASK_OUTPUT/validation-tests"
