# Experimental DiskFerry NTFS extension

This directory is an experimental FSKit extension, outside the current SwiftPM application build. It is **not release-qualified**, is not registered for automatic media matching and initially mounts read-only. `BackendReport.writeEngineQualified` remains false.

`NTFSVolume.swift`, `NTFSItem.swift`, and `bridge/ntfs_bridge.[ch]` derive from the GPL driver portion of [NTFSKit](https://github.com/whereteam/ntfskit), commit `96ecccb1b1f6dba2ecd158ed0ff9a21e7917c80d`, retrieved 2026-10-16. Upstream attributes the project to DNA MAKER COMPANY LIMITED and its contributors. The proprietary host app is not included or used. The source archive SHA-256 was `a61f714705be86dd43c821b02fdf1f278f64e446998116184a8ac0897ec0c221`.

The extension as a whole is GPL-2.0-only; the upstream C bridge declares GPL-2.0-or-later, and libntfs-3g retains its own per-file licenses. [LICENSE.GPL2](LICENSE.GPL2) contains the GPLv2 text. The repository's MIT license does not replace these licenses. DiskFerry-specific extension code is supplied under GPL-2.0-only. The standalone MIT host uses public macOS interfaces; this directory is not linked into that host.

Local changes (2026-10-16):

- Replace host identity and statistics naming with DiskFerry identifiers.
- Use DiskFerry's bounded NTFS recognition and serial-derived UUID, including every serial bit before setting UUID variant/version bits.
- Initially accept read-only resources only, with no automatic media registration.
- Remove kernel-offloaded IO and its in-flight write tracking pending separate qualification. Use FSVolume's byte-copy read/write operations.
- Remove raw-path mounts, BitLocker dependencies, formatting and repair. Checks are read-only and never clear dirty state.
- Require complete writable IO callbacks, reject unsafe/unknown health before writable engine mount, and omit automatic journal recovery.
- Bound callback offsets and lengths; forward device sync and failures rather than returning unconditional success.
- Stop IO on resource revocation and propagate shutdown failures through deactivation.
- Reject unsupported attribute changes before truncation; acknowledge only applied attributes, and reject overflowing sizes and timestamps.
- Validate resource geometry before conversion/allocation, bound IO buffers, and close the engine during unmount while retaining shutdown errors for deactivation.
- Latch callback read/write/sync failures for the entire session; refuse subsequent mutations and never report a recovered callback as a clean shutdown.
- Validate the Windows journal read-only before changing session state. Persist a dirty flag using a write-gated forensic handle before opening the normal writable engine; flush retained inode/index state and close the data handle before clearing only this session's flag.
- Test actual child-process termination against ordinary NTFS images, plus initial-marker, recovered-sync, read/write and shutdown failures. These tests do not qualify FSKit resource persistence or hardware power loss.
- Restrict public file APIs to the user namespace, checking actual inode IDs along the path and all filename parents. Reject internal metadata and $Extend entries, including aliases, before mutation while retaining root attributes and ordinary SYSTEM-flagged symlinks. Internal engine maintenance continues to use private metadata APIs.
- Apply supported creation size/time attributes through shared resource-independent operations, validate the full request before creating, serialize creation/configuration, acknowledge used attributes, and attempt cleanup only after a successful create. Preserve EEXIST destinations and report rollback failure after device faults. Unix permission mapping and real FSKit creation remain unqualified.

The engine is built from the pinned NTFS-3G source specified by `Scripts/prepare-ntfs-core.sh`. Building does not prove OS acceptance, resource access, filesystem semantics or safe writes. These require the staged tests and real signed-module qualification in [the release plan](../../docs/first-release-plan.md).
