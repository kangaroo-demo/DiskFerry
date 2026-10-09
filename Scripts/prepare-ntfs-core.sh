#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_VENDOR="$TASK_ROOT/.build/vendor"
mkdir -p "$TASK_VENDOR"

fetch_source() {
    local task_url="$1" task_name="$2" task_hash="$3"
    local task_archive="$TASK_VENDOR/$task_name"
    if [[ ! -f "$task_archive" ]]; then
        curl --fail --silent --show-error --location --max-time 120 "$task_url" --output "$task_archive.partial"
        printf '%s  %s\n' "$task_hash" "$task_archive.partial" | shasum -a 256 -c -
        mv "$task_archive.partial" "$task_archive"
    fi
    printf '%s  %s\n' "$task_hash" "$task_archive" | shasum -a 256 -c -
}

fetch_source 'https://distfiles.ariadne.space/pkgconf/pkgconf-2.3.0.tar.xz' \
    'pkgconf-2.3.0.tar.xz' '3a9080ac51d03615e7c1910a0a2a8df08424892b5f13b0628a204d3fcce0ea8b'
fetch_source 'https://tuxera.com/opensource/ntfs-3g_ntfsprogs-2026.9.28.tgz' \
    'ntfs-3g_ntfsprogs-2026.9.28.tgz' '350d9415c59f7c3fa74e23985ad2d56423c6a168337368f672e2e362d8f295c8'

if [[ ! -d "$TASK_VENDOR/pkgconf-2.3.0" ]]; then
    tar -xJf "$TASK_VENDOR/pkgconf-2.3.0.tar.xz" -C "$TASK_VENDOR"
fi
if [[ ! -d "$TASK_VENDOR/ntfs-3g-2026.9.28" ]]; then
    tar -xzf "$TASK_VENDOR/ntfs-3g_ntfsprogs-2026.9.28.tgz" -C "$TASK_VENDOR"
fi

# Build tools stay within the project. There is no make install, driver or Homebrew installation.
cd "$TASK_VENDOR/pkgconf-2.3.0"
./configure --disable-shared --enable-static --prefix="$TASK_VENDOR/pkgconf-local" > "$TASK_VENDOR/pkgconf-configure.log" 2>&1
make -j4 > "$TASK_VENDOR/pkgconf-build.log" 2>&1
cd "$TASK_VENDOR/ntfs-3g-2026.9.28"
PKG_CONFIG="$TASK_VENDOR/pkgconf-2.3.0/pkgconf" ./configure \
    --disable-ntfs-3g --disable-shared --enable-static --disable-dependency-tracking \
    --prefix="$TASK_VENDOR/ntfs-3g-local" > "$TASK_VENDOR/ntfs-configure.log" 2>&1
make -j4 > "$TASK_VENDOR/ntfs-build.log" 2>&1
printf 'Built image-only NTFS verification tools: %s\n' "$TASK_VENDOR/ntfs-3g-2026.9.28/ntfsprogs"
