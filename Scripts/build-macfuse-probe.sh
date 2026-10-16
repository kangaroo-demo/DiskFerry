#!/bin/bash
# Build the experimental read-only transport. Does not install or mount anything.
set -euo pipefail
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_ENGINE="$TASK_ROOT/.build/vendor/ntfs-3g-2026.9.28"
TASK_PREFIX="${DISKFERRY_MACFUSE_PREFIX:-/usr/local}"
TASK_OUTPUT="$TASK_ROOT/.build/macfuse-probe"
if [[ ! -f "$TASK_PREFIX/include/fuse/fuse.h" || ! -f "$TASK_PREFIX/lib/libfuse.2.dylib" ]]; then
    printf 'macFUSE development files missing. Install the official runtime, or set DISKFERRY_MACFUSE_PREFIX to its extracted usr/local directory for compile-only checks.\n' >&2
    exit 1
fi
if [[ ! -f "$TASK_ENGINE/libntfs-3g/.libs/libntfs-3g.a" ]]; then
    printf 'First run: bash Scripts/prepare-ntfs-core.sh\n' >&2
    exit 1
fi
mkdir -p "$TASK_OUTPUT"
xcrun clang -c -O2 -DHAVE_CONFIG_H=1 -include "$TASK_ENGINE/config.h" \
    -I "$TASK_ENGINE" -I "$TASK_ENGINE/include" -I "$TASK_ENGINE/include/ntfs-3g" \
    "$TASK_ROOT/Extensions/DiskFerryNTFS/bridge/ntfs_bridge.c" -o "$TASK_OUTPUT/ntfs_bridge.o"
xcrun clang -O2 -Wall -Wextra -Werror -D_FILE_OFFSET_BITS=64 \
    -I "$TASK_PREFIX/include/fuse" -I "$TASK_ROOT/Extensions/DiskFerryNTFS/bridge" \
    "$TASK_ROOT/Tools/DiskFerryMacFUSE/main.c" "$TASK_ROOT/Tools/DiskFerryMacFUSE/readonly.c" \
    "$TASK_OUTPUT/ntfs_bridge.o" "$TASK_ENGINE/libntfs-3g/.libs/libntfs-3g.a" \
    "$TASK_PREFIX/lib/libfuse.2.dylib" -framework CoreFoundation -pthread \
    -o "$TASK_OUTPUT/diskferry-macfuse-readonly"
printf 'Built: %s\nNo runtime was installed and no volume was mounted.\n' "$TASK_OUTPUT/diskferry-macfuse-readonly"
