#!/bin/bash
# Build an experimental native-architecture FSKit module without installing it.
set -euo pipefail
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
TASK_ENGINE="$TASK_ROOT/.build/vendor/ntfs-3g-2026.9.28"
TASK_SOURCE="$TASK_ROOT/Extensions/DiskFerryNTFS"
TASK_OUTPUT="$TASK_ROOT/.build/ntfs-extension"
TASK_ARCH="$(uname -m)"
TASK_APP="$TASK_ROOT/dist/experimental/DiskFerry.app"
TASK_EXTENSION="$TASK_APP/Contents/Extensions/DiskFerryNTFS.appex"
if [[ ! -f "$TASK_ENGINE/libntfs-3g/.libs/libntfs-3g.a" ]]; then
    printf 'First run: bash Scripts/prepare-ntfs-core.sh\n' >&2
    exit 1
fi
if [[ ! -d "$TASK_ROOT/dist/DiskFerry.app" ]]; then
    printf 'First run: bash Scripts/build-app.sh\n' >&2
    exit 1
fi
mkdir -p "$TASK_OUTPUT" "$TASK_APP"
xcrun clang -c -O2 -fPIC -DHAVE_CONFIG_H=1 -include "$TASK_ENGINE/config.h" \
    -I "$TASK_ENGINE" -I "$TASK_ENGINE/include" -I "$TASK_ENGINE/include/ntfs-3g" \
    "$TASK_SOURCE/bridge/ntfs_bridge.c" -o "$TASK_OUTPUT/ntfs_bridge.o"
xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library -O -target "$TASK_ARCH-apple-macos26.4" \
    -import-objc-header "$TASK_SOURCE/Bridging-Header.h" \
    "$TASK_SOURCE/DiskFerryNTFS.swift" "$TASK_SOURCE/NTFSItem.swift" "$TASK_SOURCE/NTFSVolume.swift" \
    "$TASK_SOURCE/NTFSValidation.swift" \
    "$TASK_ROOT/Sources/DiskFerryCore/Backend.swift" \
    "$TASK_OUTPUT/ntfs_bridge.o" "$TASK_ENGINE/libntfs-3g/.libs/libntfs-3g.a" \
    -framework CoreFoundation -o "$TASK_OUTPUT/DiskFerryNTFS"
ditto "$TASK_ROOT/dist/DiskFerry.app" "$TASK_APP"
mkdir -p "$TASK_EXTENSION/Contents/MacOS" "$TASK_EXTENSION/Contents/Resources/Licenses"
cp "$TASK_OUTPUT/DiskFerryNTFS" "$TASK_EXTENSION/Contents/MacOS/DiskFerryNTFS"
cp "$TASK_SOURCE/Info.plist" "$TASK_EXTENSION/Contents/Info.plist"
cp "$TASK_SOURCE/LICENSE.GPL2" "$TASK_EXTENSION/Contents/Resources/Licenses/NTFSKit-GPL2.txt"
cp "$TASK_ENGINE/COPYING" "$TASK_EXTENSION/Contents/Resources/Licenses/NTFS-3G.txt"
cp "$TASK_SOURCE/UPSTREAM.md" "$TASK_EXTENSION/Contents/Resources/Licenses/UPSTREAM.md"
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 26.4' "$TASK_APP/Contents/Info.plist"
# Ad hoc signing proves bundle integrity only. It does not grant the FSKit
# entitlement or replace Apple development/distribution provisioning.
codesign --force --sign - --entitlements "$TASK_SOURCE/Entitlements.plist" "$TASK_EXTENSION"
codesign --force --sign - "$TASK_APP"
codesign --verify --strict "$TASK_EXTENSION"
codesign --verify --strict "$TASK_APP"
printf 'Built experimental %s module: %s\nNo extension was registered or installed.\n' "$TASK_ARCH" "$TASK_APP"
