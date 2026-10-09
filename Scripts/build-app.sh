#!/bin/bash
set -euo pipefail
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
# Build both products separately for each ABI. No Rosetta is needed for cross-compilation.
for task_arch in arm64 x86_64; do
    swift build -c release --arch "$task_arch"
done
TASK_ARM_BIN="$(swift build -c release --arch arm64 --show-bin-path)"
TASK_INTEL_BIN="$(swift build -c release --arch x86_64 --show-bin-path)"
TASK_APP="$TASK_ROOT/dist/DiskFerry.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
lipo -create "$TASK_ARM_BIN/DiskFerry" "$TASK_INTEL_BIN/DiskFerry" -output "$TASK_APP/Contents/MacOS/DiskFerry"
lipo -create "$TASK_ARM_BIN/diskferry-cli" "$TASK_INTEL_BIN/diskferry-cli" -output "$TASK_ROOT/dist/diskferry"
cp Resources/Info.plist "$TASK_APP/Contents/Info.plist"
cp Resources/Brand/app-icons/icns/diskferry-graphite.icns "$TASK_APP/Contents/Resources/AppIcon.icns"
# Local development signing only. This is not a Developer ID signature or notarization.
codesign --force --sign - "$TASK_APP"
codesign --force --sign - "$TASK_ROOT/dist/diskferry"
codesign --verify --strict "$TASK_APP"
lipo "$TASK_APP/Contents/MacOS/DiskFerry" -verify_arch arm64 x86_64
lipo "$TASK_ROOT/dist/diskferry" -verify_arch arm64 x86_64
printf 'Built: %s\n' "$TASK_APP"
lipo -archs "$TASK_APP/Contents/MacOS/DiskFerry"
