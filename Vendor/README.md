# Pinned upstream source

`ntfs-3g_ntfsprogs-2026.9.28.tgz` is the unmodified upstream NTFS-3G / ntfsprogs source distribution, including its original copyright and license files. It contains source, not a compiled driver or test disk image.

- Official source: https://tuxera.com/opensource/ntfs-3g_ntfsprogs-2026.9.28.tgz
- Official release and published checksum: https://github.com/tuxera/ntfs-3g/releases/tag/2026.9.28
- Release tag commit: `7f0f841fc52cf719106c5c93bafe465004e36816`
- SHA-256: `350d9415c59f7c3fa74e23985ad2d56423c6a168337368f672e2e362d8f295c8`
- License: original per-file licenses, predominantly GPL-2.0-or-later; see `COPYING`, `COPYING.LIB` and the actual source headers inside the archive. The root MIT license does not apply to this archive.

The archive is kept in Git because the official download server returns HTTP 403 to GitHub-hosted runners. `Scripts/prepare-ntfs-core.sh` verifies its checksum before extraction and builds entirely inside `.build/vendor`. Keeping the exact distribution also makes the NTFS dependency's corresponding source available alongside DiskFerry's adapter and build scripts.

The optional build-tool dependency pkgconf remains downloaded separately with a pinned checksum. See [third-party notices](../THIRD_PARTY_NOTICES.md) and [FSKit development](../docs/fskit-development.md) for build and distribution scope.
