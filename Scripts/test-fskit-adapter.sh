#!/bin/bash
# Test validation and production volume methods on ordinary images; no mounts/devices.
set -euo pipefail
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="$TASK_ROOT/.build/fskit-adapter-tests"
TASK_ENGINE="$TASK_ROOT/.build/vendor/ntfs-3g-2026.9.28"
if [[ ! -f "$TASK_ENGINE/libntfs-3g/.libs/libntfs-3g.a" || ! -x "$TASK_ENGINE/ntfsprogs/mkntfs" ]]; then
    printf 'First run: bash Scripts/prepare-ntfs-core.sh\n' >&2
    exit 1
fi
TASK_FRAMEWORKS="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer/Library/Frameworks"
TASK_TEST_LIB="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer/usr/lib"
TASK_TEST_PRIVATE_FRAMEWORKS="${TASK_FRAMEWORKS%/Frameworks}/PrivateFrameworks"
mkdir -p "$TASK_OUTPUT"
TASK_C_FLAGS=(-c -O1 -g)
TASK_SWIFT_FLAGS=(-swift-version 5 -warnings-as-errors)
if [[ "${DISKFERRY_TEST_TSAN:-0}" == 1 ]]; then
    TASK_C_FLAGS+=(-fsanitize=thread)
    TASK_SWIFT_FLAGS+=(-sanitize=thread)
fi
xcrun clang "${TASK_C_FLAGS[@]}" -DHAVE_CONFIG_H=1 -include "$TASK_ENGINE/config.h" \
    -I "$TASK_ENGINE" -I "$TASK_ENGINE/include" -I "$TASK_ENGINE/include/ntfs-3g" \
    "$TASK_ROOT/Extensions/DiskFerryNTFS/bridge/ntfs_bridge.c" -o "$TASK_OUTPUT/ntfs_bridge.o"
xcrun swiftc "${TASK_SWIFT_FLAGS[@]}" -target "$(uname -m)-apple-macos26.4" \
    -import-objc-header "$TASK_ROOT/Extensions/DiskFerryNTFS/Bridging-Header.h" \
    -F "$TASK_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TASK_FRAMEWORKS" \
    -I "$TASK_TEST_LIB" -L "$TASK_TEST_LIB" -Xlinker -rpath -Xlinker "$TASK_TEST_LIB" \
    -Xlinker -rpath -Xlinker "$TASK_TEST_PRIVATE_FRAMEWORKS" \
    "$TASK_ROOT/Extensions/DiskFerryNTFS/NTFSValidation.swift" \
    "$TASK_ROOT/Extensions/DiskFerryNTFS/NTFSFileOperations.swift" \
    "$TASK_ROOT/Extensions/DiskFerryNTFS/NTFSVolume.swift" \
    "$TASK_ROOT/Extensions/DiskFerryNTFS/NTFSItem.swift" \
    "$TASK_ROOT/Tests/FSKitAdapterTests/CreationTests.swift" \
    "$TASK_ROOT/Tests/FSKitAdapterTests/VolumeTests.swift" \
    "$TASK_ROOT/Tests/FSKitAdapterTests/main.swift" \
    "$TASK_OUTPUT/ntfs_bridge.o" "$TASK_ENGINE/libntfs-3g/.libs/libntfs-3g.a" \
    -framework CoreFoundation -o "$TASK_OUTPUT/validation-tests"
"$TASK_OUTPUT/validation-tests" "$TASK_ROOT"
