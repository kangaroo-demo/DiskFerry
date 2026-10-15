// SPDX-License-Identifier: GPL-2.0-only
// Derived from NTFSKit 96ecccb1 (DNA MAKER COMPANY LIMITED and contributors).
// Modified for DiskFerry 2026-10-16; see UPSTREAM.md.

import Foundation
import FSKit
import os

/// Only FSBlockDeviceResource implements this interface in the app. Tests use
/// ordinary image files; they do not emulate or qualify FSKit cache semantics.
protocol NTFSBlockIO: AnyObject {
    var blockSize: UInt64 { get }
    var blockCount: UInt64 { get }
    var isRevoked: Bool { get }
    func read(into buffer: UnsafeMutableRawBufferPointer, startingAt offset: off_t, length: Int) throws -> Int
    func write(from buffer: UnsafeRawBufferPointer, startingAt offset: off_t, length: Int) throws -> Int
    func metadataRead(into buffer: UnsafeMutableRawBufferPointer, startingAt offset: off_t, length: Int) throws
    func metadataWrite(from buffer: UnsafeRawBufferPointer, startingAt offset: off_t, length: Int) throws
    func metadataFlush() throws
}

extension FSBlockDeviceResource: NTFSBlockIO {}

/// NTFS volume backed by libntfs-3g through the nk_* C bridge.
/// libntfs-3g is not thread-safe → every engine call goes through one serial queue.
final class NTFSVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations {

    private let log = Logger(subsystem: "dev.diskferry.app.ntfs.NTFSModule", category: "volume")
    private let engineQueue = DispatchQueue(label: "dev.diskferry.app.ntfs.engine")

    private let resource: NTFSBlockIO
    /// Becomes true if a read-write engine mount fails (hibernated Windows,
    /// unrecoverable journal) and we fall back to read-only. Lock-guarded:
    /// written during mount, read from concurrent upcall threads.
    private let roLock = NSLock()
    private var _readOnly: Bool
    private var readOnly: Bool {
        get { roLock.lock(); defer { roLock.unlock() }; return _readOnly }
        set { roLock.lock(); defer { roLock.unlock() }; _readOnly = newValue }
    }

    private var vol: OpaquePointer?              // nk_volume*
    /// unmount has no error channel; retain shutdown errors for deactivate.
    private var shutdownError: Int32 = 0       // engineQueue only
    private var nextID: UInt64 = 100
    private var idByPath: NTFSPathMap<FSItem.Identifier> = ["/": .rootDirectory]
    /// Per-directory listing generation (keyed by directory path), bumped when
    /// THAT directory's entries change — a resumed readdir must not fail on
    /// unrelated writes elsewhere. Values come from one counter so a path
    /// never sees a reused generation; missing entries read as 1.
    private var dirGen: NTFSPathMap<UInt64> = [:]
    private var genCounter: UInt64 = 1
    /// One live NTFSItem instance per path — FSKit tracks items by object
    /// identity; handing out fresh instances per lookup leaks phantom vnodes
    /// (files stay "open" forever and unlink is deferred indefinitely).
    private var itemByPath: NTFSPathMap<NTFSItem> = [:]
    /// Removed/replaced items retain a root-level private link until reclaim.
    /// Keeping these outside their former directory permits removing that
    /// directory while an unlinked child is still open.
    private var pendingByPath: NTFSPathMap<NTFSItem> = [:]
    /// A failed compound rename can leave paths uncertain. Stop namespace
    /// access until a new volume instance performs read-only recovery.
    private var namespaceError: Int32 = 0
    /// FSKit doesn't promise upcalls arrive serialized — all namespace-cache
    /// state above is guarded by this lock (recursive: item() calls id()).
    private let stateLock = NSRecursiveLock()

    private func item(path: String, kind: FSItem.ItemType) -> NTFSItem {
        stateLock.lock(); defer { stateLock.unlock() }
        if let existing = itemByPath[path] { return existing }
        let fresh = NTFSItem(path: path, kind: kind, identifier: id(for: path))
        itemByPath[path] = fresh
        return fresh
    }

    private func requireLive(_ item: NTFSItem, linked: Bool = false) throws {
        if item.reclaimed { throw posix(ESTALE) }
        if namespaceError != 0 { throw posix(namespaceError) }
        if linked && item.unlinked { throw posix(ENOENT) }
    }

    /// Lock order is namespace -> engine. Snapshotting a path alone cannot
    /// protect it: rename could remove/reuse the name before engine access.
    private func withItemPath<T>(_ item: NTFSItem, _ body: (String) throws -> T) throws -> T {
        try stateLock.withLock {
            try requireLive(item)
            return try body(item.path)
        }
    }

    private func pendingName(for path: String) -> String {
        var name = ".diskferry-unlinked-\(UUID().uuidString)-"
        for character in (path as NSString).lastPathComponent {
            if name.utf16.count + String(character).utf16.count > 255 { break }
            name.append(character)
        }
        return name
    }

    private func requireEmptyDirectory(_ item: NTFSItem) throws {
        guard item.kind == .directory else { return }
        if try !visibleEntries(in: item).isEmpty { throw posix(ENOTEMPTY) }
    }

    /// Shared by enumeration and directory validation. Pending backing links
    /// are outside the public namespace, including explicit name lookups.
    func visibleEntries(in directory: NTFSItem) throws -> [(name: String, isDir: Bool, size: Int64)] {
        try stateLock.withLock {
            try requireLive(directory)
            let collector = DirCollector()
            let (rc, e) = engine {
                directory.path.withCString {
                    nk_list(vol, $0, dirCollectCallback, Unmanaged.passUnretained(collector).toOpaque())
                }
            }
            guard rc == 0 else { throw posix(errno: e) }
            return collector.items.filter { pendingByPath[directory.childPath($0.name)] == nil }
        }
    }

    // Sector-aligned scratch state for the nk_io callbacks. The sandbox forbids
    // opening /dev, so all engine I/O goes through FSBlockDeviceResource.
    //
    // TWO device paths, switched automatically:
    // - The kernel buffer cache (metadataRead/metadataWrite) only comes alive
    //   once the KERNEL MOUNT exists — during activate it returns EIO. So
    //   engine I/O starts on the plain read/write API and flips to buffer-cache
    //   I/O the moment a metadataRead succeeds. All file data and metadata use
    //   this same engine path; kernel-offloaded I/O is disabled.
    /// Device I/O mode; only touched from engineQueue (all device callbacks
    /// originate from engine calls serialized there).
    fileprivate enum IOMode { case probing, metadata }
    fileprivate var ioMode: IOMode = .probing
    /// Set once the kernel mount exists (engineQueue only). From then on a
    /// buffer-cache error is a real error — falling back to plain writes
    /// could mix stale plain reads with cached metadata.
    fileprivate var kernelMounted = false

    /// The ONE buffer-cache block size. The cache is keyed by offset and every
    /// access to a region must use the same (offset, length) — and purge
    /// segments must match cached blocks exactly — so all engine device I/O
    /// must use this fixed granule. Chosen once per engine
    /// open, before the engine touches the device (engineQueue only).
    fileprivate var cacheBlockSize = 512
    /// Prefer 4 KiB for compatible NTFS geometry, otherwise the logical block
    /// size. All engine accesses use the same cache granule.
    private func pickCacheBlockSize() -> Int {
        let bs = deviceBlockSize
        guard bs > 0, deviceSize % 4096 == 0, 4096 % bs == 0 else { return bs }
        let boot = UnsafeMutableRawBufferPointer.allocate(byteCount: bs, alignment: bs)
        defer { boot.deallocate() }
        // Plain read: valid pre- and post-mount, and keeps the cache keyed
        // only by the final granule.
        guard let n = try? resource.read(into: boot, startingAt: 0, length: bs),
              n == bs else { return bs }
        let bps = Int(boot[0x0B]) | Int(boot[0x0C]) << 8
        let spc = Int(boot[0x0D])
        // NTFS encoding; untrusted (probe may not have run, media may have
        // changed): cap the exponent like probe does so this can't trap.
        let exp = 256 - spc
        let cs = spc > 0x80 ? (exp < 22 ? bps << exp : 0) : bps * spc
        return cs > 0 && cs % 4096 == 0 ? 4096 : bs
    }

    fileprivate var deviceBlockSize: Int {
        // Use the LOGICAL block size: it's the unit blockCount is measured in,
        // so deviceSize stays an exact multiple and tail I/O stays aligned.
        // (max with physicalBlockSize breaks on 512e disks whose blockCount
        // isn't a multiple of 8.)
        Int(resource.blockSize)
    }
    fileprivate var deviceSize: Int64 {
        // blockCount is in units of blockSize (NOT deviceBlockSize) — using
        // the wrong unit inflated the size 8x and pushed end-of-volume reads
        // (NTFS backup boot sector) past the device, which EIOs.
        Int64(resource.blockCount) * Int64(resource.blockSize)
    }

    /// Aligned pread through the kernel buffer cache: read whole sectors
    /// covering [offset, offset+count) and copy out the window. -1 on error.
    fileprivate func devicePread(_ buf: UnsafeMutableRawPointer, _ count: Int64, _ offset: Int64) -> Int64 {
        guard !resource.isRevoked else { return -1 }
        let bs = Int64(cacheBlockSize)
        if offset < 0 || count < 0 || count > 16 * 1024 * 1024 || offset > deviceSize || count > deviceSize - offset { return -1 }
        let end = min(offset + count, deviceSize)
        if offset >= deviceSize || end <= offset { return 0 }
        let alignedStart = (offset / bs) * bs
        let alignedEnd = end % bs == 0 ? end : end + (bs - end % bs)
        let alignedLen = Int(alignedEnd - alignedStart)
        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: alignedLen,
                                                             alignment: Int(bs))
        defer { scratch.deallocate() }
        do {
            try readAligned(into: scratch, at: alignedStart, length: alignedLen)
            let skip = Int(offset - alignedStart)
            let avail = max(0, min(Int(end - offset), alignedLen - skip))
            if avail > 0 {
                memcpy(buf, scratch.baseAddress!.advanced(by: skip), avail)
            }
            return Int64(avail)
        } catch {
            log.error("devicePread(\(offset), \(count)) failed: \(error, privacy: .public)")
            return -1
        }
    }

    /// Aligned whole-block read through the current mode, upgrading to
    /// buffer-cache I/O as soon as the kernel accepts it.
    /// `start`/`length` are cacheBlockSize-aligned; issued one cache block at
    /// a time so every cache access uses the same (offset, length) pair.
    private func readAligned(into scratch: UnsafeMutableRawBufferPointer,
                             at start: Int64, length: Int) throws {
        dispatchPrecondition(condition: .onQueue(engineQueue))
        let g = cacheBlockSize
        for o in stride(from: 0, to: length, by: g) {
            try readBlock(into: UnsafeMutableRawBufferPointer(rebasing: scratch[o..<o + g]),
                          at: start + Int64(o), length: g)
        }
    }

    private func readBlock(into scratch: UnsafeMutableRawBufferPointer,
                           at start: Int64, length: Int) throws {
        if ioMode == .metadata {
            try resource.metadataRead(into: scratch, startingAt: off_t(start),
                                      length: length)
            return
        }
        do {
            try resource.metadataRead(into: scratch, startingAt: off_t(start),
                                      length: length)
            ioMode = .metadata
            log.info("device I/O upgraded to kernel buffer cache")
        } catch {
            guard !kernelMounted else { throw error }
            let n = try resource.read(into: scratch, startingAt: off_t(start),
                                      length: length)
            guard n == length else { throw posix(EIO) }
        }
    }

    /// Aligned whole-block write. Upgrades to buffer-cache I/O the same way
    /// reads do. After mount, errors must propagate instead of mixing plain
    /// resource writes with cached metadata.
    private func writeAligned(_ scratch: UnsafeMutableRawBufferPointer,
                              at start: Int64, length: Int) throws {
        dispatchPrecondition(condition: .onQueue(engineQueue))
        let g = cacheBlockSize
        for o in stride(from: 0, to: length, by: g) {
            try writeBlock(UnsafeMutableRawBufferPointer(rebasing: scratch[o..<o + g]),
                           at: start + Int64(o), length: g)
        }
    }

    private func writeBlock(_ scratch: UnsafeMutableRawBufferPointer,
                            at start: Int64, length: Int) throws {
        if ioMode == .metadata {
            try resource.metadataWrite(from: UnsafeRawBufferPointer(scratch),
                                       startingAt: off_t(start), length: length)
            return
        }
        do {
            try resource.metadataWrite(from: UnsafeRawBufferPointer(scratch),
                                       startingAt: off_t(start), length: length)
            ioMode = .metadata
            log.info("device I/O upgraded to kernel buffer cache (write)")
        } catch {
            // Pre-mount only: buffer cache not attached yet, no kernel I/O in
            // flight, plain write is safe.
            guard !kernelMounted else { throw error }
            let n = try resource.write(from: UnsafeRawBufferPointer(scratch),
                                       startingAt: off_t(start), length: length)
            guard n == length else { throw posix(EIO) }
        }
    }

    /// Aligned pwrite through the kernel buffer cache, with read-modify-write
    /// on partial edge sectors.
    fileprivate func devicePwrite(_ buf: UnsafeRawPointer, _ count: Int64, _ offset: Int64) -> Int64 {
        guard !resource.isRevoked, !readOnly else { return -1 }
        let bs = Int64(cacheBlockSize)
        if offset < 0 || count < 0 || count > 16 * 1024 * 1024 || offset > deviceSize || count > deviceSize - offset { return -1 }
        let end = min(offset + count, deviceSize)
        if offset >= deviceSize || end <= offset { return 0 }
        let alignedStart = (offset / bs) * bs
        let alignedEnd = end % bs == 0 ? end : end + (bs - end % bs)
        let alignedLen = Int(alignedEnd - alignedStart)
        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: alignedLen,
                                                             alignment: Int(bs))
        defer { scratch.deallocate() }
        do {
            // RMW: preload edge sectors when the write is not perfectly aligned.
            if offset != alignedStart || end != alignedEnd {
                try readAligned(into: scratch, at: alignedStart, length: alignedLen)
            }
            let skip = Int(offset - alignedStart)
            memcpy(scratch.baseAddress!.advanced(by: skip), buf, Int(end - offset))
            // Keep writes synchronous; no delayed-write/purge protocol has
            // been qualified for this adapter.
            try writeAligned(scratch, at: alignedStart, length: alignedLen)
            return end - offset
        } catch {
            log.error("devicePwrite(\(offset), \(count)) failed: \(error, privacy: .public)")
            return -1
        }
    }

    init(resource: NTFSBlockIO, volumeName: FSFileName,
         volumeID: FSVolume.Identifier, readOnly: Bool) {
        self.resource = resource
        self._readOnly = readOnly
        super.init(volumeID: volumeID, volumeName: volumeName)
        wantReadOnlyMount = readOnly
    }

    fileprivate func deviceSync() -> Int32 {
        guard !resource.isRevoked, shutdownError == 0 else { return -1 }
        // Plain pre-mount writes are synchronous resource operations; once
        // metadata IO is active, flush the resource cache before success.
        if ioMode == .metadata {
            do { try resource.metadataFlush() } catch { return -1 }
        }
        return 0
    }

    // MARK: engine

    private func openEngine() throws {
        try engineQueue.sync {
            guard vol == nil else { return }
            guard !resource.isRevoked else { throw posix(ENXIO) }
            guard shutdownError == 0 else { throw posix(shutdownError) }
            _ = try NTFSResourceGeometry(blockSize: resource.blockSize, blockCount: resource.blockCount)
            cacheBlockSize = pickCacheBlockSize()
            var io = nk_io(ctx: Unmanaged.passUnretained(self).toOpaque(),
                           pread: nkPreadTrampoline,
                           pwrite: nkPwriteTrampoline,
                           sync: nkSyncTrampoline,
                           size: deviceSize,
                           readonly: readOnly ? 1 : 0)
            var errbuf = [CChar](repeating: 0, count: 256)
            if let handle = nk_mount_io(&io, &errbuf, 256) {
                vol = handle
                return
            }
            let reason = String(cString: errbuf)
            log.error("nk_mount_io failed: \(reason, privacy: .public)")
            // Hibernated Windows / unrecoverable journal refuse read-write —
            // fall back to read-only instead of failing the whole mount, so
            // the user can still get at their files (the app explains why).
            if !readOnly {
                io.readonly = 1
                if let handle = nk_mount_io(&io, &errbuf, 256) {
                    log.info("falling back to READ-ONLY mount: \(reason, privacy: .public)")
                    readOnly = true
                    wantReadOnlyMount = true
                    vol = handle
                    return
                }
            }
            throw self.posix(EIO)
        }
    }

    @discardableResult
    private func closeEngine() -> Int32 {
        engineQueue.sync {
            let rc: Int32 = vol.map { nk_umount($0) } ?? 0
            vol = nil
            if rc != 0 { shutdownError = EIO }
            if !readOnly && ioMode == .metadata {
                do { try resource.metadataFlush() } catch { shutdownError = EIO }
            }
            // If FSKit reactivates this instance, the next engine open happens
            // pre-mount again — the buffer cache won't be attached, so start
            // back in probing mode.
            ioMode = .probing
            kernelMounted = false
            return shutdownError == 0 ? 0 : -1
        }
    }

    /// True while the engine has the device open (fsck repair/format must not
    /// do raw RMW under it).
    var isEngineOpen: Bool { engineQueue.sync { vol != nil } }

    /// Shared by both lifecycle callbacks. Pending storage must be freed
    /// before a clean engine close, and no item may survive into a new mount.
    @discardableResult
    func finishVolume() -> Int32 {
        stateLock.withLock {
            engineQueue.sync {
                if vol != nil {
                    for path in pendingByPath.keys {
                        if path.withCString({ nk_delete(vol, $0) }) != 0 {
                            shutdownError = EIO
                            // Latch the failed shutdown in the engine too;
                            // deviceSync now refuses to acknowledge persistence.
                            _ = nk_sync(vol)
                            break
                        }
                    }
                }
            }
            let result = closeEngine()
            for item in Array(itemByPath.values) + Array(pendingByPath.values) { item.reclaimed = true }
            itemByPath.removeAll()
            pendingByPath.removeAll()
            idByPath = ["/": .rootDirectory]
            dirGen.removeAll()
            return result
        }
    }

    private func id(for path: String) -> FSItem.Identifier {
        stateLock.lock(); defer { stateLock.unlock() }
        if let existing = idByPath[path] { return existing }
        nextID += 1
        let newID = FSItem.Identifier(rawValue: nextID) ?? .invalid
        idByPath[path] = newID
        return newID
    }

    /// Namespace mutation bookkeeping under one lock: bump the generation of
    /// every directory (path) whose entries changed.
    private func mutateNamespace(_ dirs: [String], _ body: () -> Void = {}) {
        stateLock.lock(); defer { stateLock.unlock() }
        for d in dirs { genCounter += 1; dirGen[d] = genCounter }
        body()
    }

    private func parentPath(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// Run one engine call on the engine queue and capture errno right after
    /// it, before anything else can clobber it (libntfs-3g reports via errno).
    private func engine<T>(_ body: () -> T) -> (T, Int32) {
        engineQueue.sync {
            errno = 0
            let r = body()
            return (r, errno)
        }
    }

    private func posix(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    /// Error for a failed engine call: the captured errno, or `fallback` when
    /// the bridge failed without setting one.
    private func posix(errno e: Int32, or fallback: Int32 = EIO) -> NSError {
        posix(e != 0 ? e : fallback)
    }

    // MARK: FSVolume.Operations

    private var _wantReadOnlyMount = false
    fileprivate var wantReadOnlyMount: Bool {
        get { roLock.withLock { _wantReadOnlyMount } }
        set { roLock.withLock { _wantReadOnlyMount = newValue } }
    }

    /// FSKit reads this after mount() replies — if the engine fell back to
    /// read-only (hibernated Windows, bad journal), the KERNEL mount goes
    /// read-only too, so Finder/statfs agree with reality. Only on 26.4+
    /// (FSMountOptions is a V2.4 API).
    @available(macOS 26.4, *)
    var requestedMountOptions: FSVolume.MountOptions {
        get { readOnly || wantReadOnlyMount ? [.readOnly] : [] }
        set { wantReadOnlyMount = newValue.contains(.readOnly) }
    }

    /// The module retains unlinked backing data until reclaim itself. Real
    /// FSKit lifecycle ordering still needs signed-system qualification.
    @available(macOS 26.0, *)
    var enableOpenUnlinkEmulation = false

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        // Honest advertising: createLink is ENOTSUP and our IDs are per-mount
        // path counters, not stable MFT references (flip both when those land).
        caps.supportsHardLinks = false
        caps.supportsSymbolicLinks = true
        caps.supportsPersistentObjectIDs = false
        caps.doesNotSupportImmutableFiles = true
        caps.doesNotSupportSettingFilePermissions = true
        caps.supports64BitObjectIDs = true
        return caps
    }

    var volumeStatistics: FSStatFSResult {
        let stats = FSStatFSResult(fileSystemTypeName: "diskferry_ntfs")
        var total: Int64 = 0, free: Int64 = 0
        var cluster: Int32 = 0
        engineQueue.sync { _ = nk_statvfs(vol, &total, &free, &cluster) }
        let bs = cluster > 0 ? Int(cluster) : 4096
        stats.blockSize = bs
        stats.ioSize = 1 << 20
        stats.totalBlocks = UInt64(max(0, total)) / UInt64(bs)
        stats.availableBlocks = UInt64(max(0, free)) / UInt64(bs)
        stats.freeBlocks = stats.availableBlocks
        return stats
    }

    // MARK: PathConf

    var maximumLinkCount: Int { 1023 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }

    // MARK: lifecycle

    func activate(options: FSTaskOptions) async throws -> FSItem {
        try activateVolume()
    }

    func activateVolume() throws -> FSItem {
        try stateLock.withLock {
            try openEngine()
            // 128 UTF-16 units can need well over 256 UTF-8 bytes (CJK).
            var label = [CChar](repeating: 0, count: 1024)
            engineQueue.sync { _ = nk_label(vol, &label, 1024) }
            let name = String(cString: label)
            if !name.isEmpty { self.name = FSFileName(string: name) }
            return item(path: "/", kind: .directory)
        }
    }

    func deactivate(options: FSDeactivateOptions) async throws {
        // Also returns a failure retained by the nonthrowing unmount callback.
        let rc = finishVolume()
        guard rc == 0 else { throw posix(EIO) }
    }
    func mount(options: FSTaskOptions) async throws {
        try stateLock.withLock {
            try openEngine()
            engineQueue.sync { kernelMounted = true }
        }
    }
    func unmount() async {
        if finishVolume() != 0 { log.error("engine shutdown failed during unmount") }
    }

    func synchronize(flags: FSSyncFlags) async throws {
        let (rc, e) = engine { nk_sync(vol) }
        guard rc == 0 else { throw posix(errno: e) }
        if !readOnly { try resource.metadataFlush() }
    }

    // MARK: attributes

    private func makeAttributes(path: String, st: nk_stat,
                                identifier: FSItem.Identifier, unlinked: Bool = false) -> FSItem.Attributes {
        let kind: FSItem.ItemType = st.is_symlink != 0 ? .symlink : st.is_dir != 0 ? .directory : .file
        let attrs = NTFSAttributePolicy.defaults(type: kind, uid: getuid(), gid: getgid())
        attrs.size = UInt64(max(0, st.size))
        attrs.allocSize = UInt64(max(0, st.alloc_size))
        attrs.linkCount = unlinked ? 0 : 1
        attrs.fileID = identifier
        attrs.parentID = path == "/" ? .parentOfRoot : id(for: (path as NSString).deletingLastPathComponent)
        attrs.uid = getuid()
        attrs.gid = getgid()
        attrs.flags = 0
        // All data stays on the serialized, byte-copy engine path.
        attrs.inhibitKernelOffloadedIO = true
        attrs.modifyTime = timespec(tv_sec: Int(st.mtime), tv_nsec: Int(st.mtime_nsec))
        attrs.accessTime = timespec(tv_sec: Int(st.atime), tv_nsec: Int(st.atime_nsec))
        attrs.changeTime = timespec(tv_sec: Int(st.ctime), tv_nsec: Int(st.ctime_nsec))
        attrs.birthTime = timespec(tv_sec: Int(st.btime), tv_nsec: Int(st.btime_nsec))
        return attrs
    }

    func attributes(_ request: FSItem.GetAttributesRequest, of item: FSItem) async throws -> FSItem.Attributes {
        guard let item = item as? NTFSItem else { throw posix(EINVAL) }
        return try withItemPath(item) { path in
            var st = nk_stat()
            let (rc, e) = engine { path.withCString { nk_stat_path(vol, $0, &st) } }
            guard rc == 0 else { throw posix(errno: e, or: ENOENT) }
            return makeAttributes(path: path, st: st, identifier: item.identifier, unlinked: item.unlinked)
        }
    }

    func setAttributes(_ request: FSItem.SetAttributesRequest, on item: FSItem) async throws -> FSItem.Attributes {
        guard let item = item as? NTFSItem else { throw posix(EINVAL) }
        return try stateLock.withLock {
            try requireLive(item)
            let path = item.path
            var st = nk_stat()
            let (rc, e) = engine { path.withCString { nk_stat_path(vol, $0, &st) } }
            guard rc == 0 else { throw posix(errno: e, or: ENOENT) }
            let current = makeAttributes(path: path, st: st, identifier: item.identifier)
            let unchanged = try NTFSAttributePolicy.validate(request, current: current, readOnly: readOnly)
            try engineQueue.sync {
                try NTFSFileOperations.apply(request, to: path, type: current.type, volume: vol, unchanged: unchanged)
                errno = 0
                guard path.withCString({ nk_stat_path(vol, $0, &st) }) == 0 else {
                    throw posix(errno: errno)
                }
            }
            return makeAttributes(path: path, st: st, identifier: item.identifier, unlinked: item.unlinked)
        }
    }

    // MARK: lookup / enumerate

    private func resolvedChild(named name: String, in directory: NTFSItem) throws -> (path: String, name: String, stat: nk_stat) {
        try NTFSFileOperations.validateName(name)
        var actual = [CChar](repeating: 0, count: 1024)
        var st = nk_stat()
        let (rc, error) = engine {
            directory.path.withCString { parent in
                name.withCString { nk_lookup_child(vol, parent, $0, &actual, actual.count, &st) }
            }
        }
        guard rc == 0 else { throw posix(errno: error, or: ENOENT) }
        let storedName = String(cString: actual)
        let path = directory.childPath(storedName)
        if pendingByPath[path] != nil { throw posix(ENOENT) }
        return (path, storedName, st)
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) {
        guard let dir = directory as? NTFSItem, let childName = name.string else { throw posix(EINVAL) }
        // stat + item() under stateLock (lock order stateLock → engineQueue):
        // a concurrent rename can't slip between them, so there is never a
        // second NTFSItem for one file or one cached under a dead path.
        return try stateLock.withLock {
            try requireLive(dir, linked: true)
            let resolved = try resolvedChild(named: childName, in: dir)
            let st = resolved.stat
            let kind: FSItem.ItemType = st.is_symlink != 0 ? .symlink
                                      : st.is_dir != 0 ? .directory : .file
            return (item(path: resolved.path, kind: kind), FSFileName(string: resolved.name))
        }
    }

    func enumerateDirectory(_ directory: FSItem,
                            startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker) async throws -> FSDirectoryVerifier {
        guard let dir = directory as? NTFSItem else { throw posix(EINVAL) }
        return try stateLock.withLock {
            try requireLive(dir)
            // Hold the namespace lock through packing. Entry paths, IDs, attributes
            // and the returned verifier must describe the same directory state.
            let generation = dirGen[dir.path, default: 1]
            if cookie.rawValue != 0 && verifier.rawValue != generation {
                throw FSError(.invalidDirectoryCookie)
            }

            let contents = try visibleEntries(in: dir)

            var entries: [(name: String, type: FSItem.ItemType, path: String)] = []
            if attributes == nil {
                let parentPath = dir.path == "/" ? "/"
                    : (dir.path as NSString).deletingLastPathComponent
                entries.append((".", .directory, dir.path))
                entries.append(("..", .directory, parentPath))
            }
            for e in contents {
                entries.append((e.name, e.isDir ? .directory : .file, dir.childPath(e.name)))
            }

            guard var index = Int(exactly: cookie.rawValue) else {
                throw FSError(.invalidDirectoryCookie)
            }
            while index < entries.count {
                let entry = entries[index]
                // FSKit drops entries packed without attributes when it asked for
                // them — fetch per entry (path-addressed engine, one stat each).
                var entryAttrs: FSItem.Attributes? = nil
                let entryID = NTFSPath.equal(entry.path, dir.path) ? dir.identifier : id(for: entry.path)
                if attributes != nil {
                    var st = nk_stat()
                    let (rc, error) = engine { entry.path.withCString { nk_stat_path(vol, $0, &st) } }
                    guard rc == 0 else { throw posix(errno: error) }
                    entryAttrs = makeAttributes(path: entry.path, st: st, identifier: entryID,
                                                unlinked: NTFSPath.equal(entry.path, dir.path) && dir.unlinked)
                }
                // nk_dirent has no symlink flag; the per-entry stat (when asked
                // for attributes) knows the real type.
                let ok = packer.packEntry(name: FSFileName(string: entry.name),
                                          itemType: entryAttrs?.type ?? entry.type,
                                          itemID: entryID,
                                          nextCookie: FSDirectoryCookie(rawValue: UInt64(index + 1)),
                                          attributes: entryAttrs)
                if !ok { break }
                index += 1
            }
            return FSDirectoryVerifier(rawValue: generation)
        }
    }

    // MARK: create / remove / rename

    func createItem(named name: FSFileName,
                    type: FSItem.ItemType,
                    inDirectory directory: FSItem,
                    attributes newAttributes: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) {
        guard let dir = directory as? NTFSItem, let childName = name.string else { throw posix(EINVAL) }
        if readOnly { throw posix(EROFS) }
        // Only regular files and directories exist in the engine — never
        // "create" a FIFO/socket/device as a regular file.
        guard type == .file || type == .directory else { throw posix(ENOTSUP) }
        // Engine op + cache bookkeeping in one stateLock hold (see lookupItem).
        return try stateLock.withLock {
            try requireLive(dir, linked: true)
            let dirPath = dir.path
            let childPath = dir.childPath(childName)
            do {
                try engineQueue.sync {
                    try NTFSFileOperations.create(volume: vol, parent: dirPath, name: childName,
                                                  type: type, attributes: newAttributes, readOnly: readOnly)
                }
            } catch {
                // A failed configuration may have created and removed the
                // name, or left it behind after a device fault.
                mutateNamespace([dirPath, childPath])
                if (error as NSError).userInfo["DiskFerryRollbackFailed"] as? Bool == true {
                    log.error("create rollback failed at \(childPath, privacy: .public)")
                }
                throw error
            }
            mutateNamespace([dirPath, childPath])
            return (item(path: childPath, kind: type), name)
        }
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem) async throws {
        guard let item = item as? NTFSItem, let directory = directory as? NTFSItem,
              let name = name.string else { throw posix(EINVAL) }
        if readOnly { throw posix(EROFS) }
        try stateLock.withLock {
            try requireLive(item, linked: true)
            try requireLive(directory, linked: true)
            let path = item.path
            guard NTFSPath.equal(try resolvedChild(named: name, in: directory).path, path) else { throw posix(ENOENT) }
            guard path != "/" else { throw posix(EPERM) }
            try requireEmptyDirectory(item)
            let name = pendingName(for: path)
            let parked = "/" + name
            let (rc, e) = engine { path.withCString { old in name.withCString { nk_rename(vol, old, "/", $0) } } }
            log.info("removeItem \(path, privacy: .public) rc=\(rc) errno=\(e)")
            guard rc == 0 else { throw posix(errno: e) }
            mutateNamespace([parentPath(path), path]) {
                idByPath[path] = nil
                itemByPath[path] = nil
                item.path = parked
                item.unlinked = true
                pendingByPath[parked] = item
            }
        }
    }

    func renameItem(_ item: FSItem,
                    inDirectory sourceDirectory: FSItem,
                    named sourceName: FSFileName,
                    to destinationName: FSFileName,
                    inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?) async throws -> FSFileName {
        guard let item = item as? NTFSItem,
              let sourceDir = sourceDirectory as? NTFSItem,
              let sourceLeaf = sourceName.string,
              let destDir = destinationDirectory as? NTFSItem,
              let newName = destinationName.string else { throw posix(EINVAL) }
        if readOnly { throw posix(EROFS) }

        // Engine ops + cache re-key in ONE stateLock hold: a concurrent
        // lookup can't insert a second NTFSItem between them (see lookupItem).
        try stateLock.withLock {
            try requireLive(item, linked: true)
            try requireLive(sourceDir, linked: true)
            try requireLive(destDir, linked: true)
            let oldPath = item.path
            let destPath = destDir.path
            let newPath = destDir.childPath(newName)
            guard NTFSPath.equal(try resolvedChild(named: sourceLeaf, in: sourceDir).path, oldPath) else { throw posix(ENOENT) }
            try NTFSFileOperations.validateName(newName)
            guard oldPath != "/" else { throw posix(EPERM) }

            // A directory must never move into itself or its own subtree — the
            // engine's link-then-delete would happily create a cycle.
            if NTFSPath.equal(destPath, oldPath) || NTFSPath.hasPrefix(destPath, oldPath + "/") {
                throw posix(EINVAL)
            }

            // Park the victim under a private root link before replacing it;
            // reclaim releases its data after the last reference. A failed
            // source rename attempts to restore the victim's original name.
            let over = (overItem as? NTFSItem).flatMap { $0 === item ? nil : $0 }
            let overPath = over?.path ?? ""
            var parked: String? = nil
            if let over {
                try requireLive(over, linked: true)
                guard NTFSPath.equal(try resolvedChild(named: newName, in: destDir).path, overPath) else { throw posix(ENOENT) }
                if item.kind == .directory && over.kind != .directory { throw posix(ENOTDIR) }
                if item.kind != .directory && over.kind == .directory { throw posix(EISDIR) }
                // POSIX: renaming onto another link of the same file is a
                // no-op (parking + deleting would drop one of the links).
                var sa = nk_stat(), sb = nk_stat()
                let same = engineQueue.sync {
                    oldPath.withCString { nk_stat_path(vol, $0, &sa) } == 0 &&
                    overPath.withCString { nk_stat_path(vol, $0, &sb) } == 0
                } && sa.inode == sb.inode
                if same { return }
                try requireEmptyDirectory(over)
                let tmpName = pendingName(for: overPath)
                let (prc, pe) = engine {
                    overPath.withCString { op in
                        tmpName.withCString { np in nk_rename(vol, op, "/", np) }
                    }
                }
                guard prc == 0 else { throw posix(errno: pe) }
                parked = "/" + tmpName
            }

            let (rc, e) = engine {
                oldPath.withCString { op in
                    destPath.withCString { dp in
                        newName.withCString { np in nk_rename(vol, op, dp, np) }
                    }
                }
            }
            guard rc == 0 else {
                if let parked {
                    let overDir = parentPath(overPath)
                    let overName = (overPath as NSString).lastPathComponent
                    let (rrc, _) = engine {
                        parked.withCString { op in
                            overDir.withCString { dp in
                                overName.withCString { np in nk_rename(vol, op, dp, np) }
                            }
                        }
                    }
                    if rrc != 0 {
                        if let over {
                            over.path = parked
                            over.unlinked = true
                            pendingByPath[parked] = over
                        }
                        namespaceError = EIO
                        engineQueue.sync { shutdownError = EIO; _ = nk_sync(vol) }
                        log.error("rename-over rollback failed; victim kept at \(parked, privacy: .public)")
                        throw posix(EIO)
                    }
                }
                throw posix(errno: e)
            }
            if let parked, let over {
                // FSKit owns the last-reference decision. Retain the old data
                // under a private root link until reclaim, so existing open
                // handles keep using the victim while lookup finds the source.
                over.path = parked
                over.unlinked = true
                pendingByPath[parked] = over
            }

            // Evict the replaced item's cache entries (and any cached
            // descendants), or the next lookup of the destination path would
            // resurrect the dead item object. Then re-key: the kernel keeps
            // using the SAME item object after rename (it may be open) —
            // rewrite its path in place and re-key the caches, including
            // every cached descendant when a directory moves. idByPath is
            // walked independently: enumeration seeds ids for paths with no
            // live item.
            mutateNamespace([parentPath(oldPath), destPath, oldPath, newPath]) {
                if over != nil {
                    let overPrefix = overPath + "/"
                    itemByPath[overPath] = nil
                    idByPath[overPath] = nil
                    for p in itemByPath.keys where NTFSPath.hasPrefix(p, overPrefix) {
                        itemByPath[p] = nil
                    }
                    for p in idByPath.keys where NTFSPath.hasPrefix(p, overPrefix) {
                        idByPath[p] = nil
                    }
                }
                let oldPrefix = oldPath + "/"
                itemByPath[oldPath] = nil
                item.path = newPath
                itemByPath[newPath] = item
                for p in itemByPath.keys.filter({ NTFSPath.hasPrefix($0, oldPrefix) }) {
                    let np = newPath + "/" + p.dropFirst(oldPrefix.count)
                    let child = itemByPath.removeValue(forKey: p)!
                    child.path = np
                    itemByPath[np] = child
                }
                let movedID = idByPath.removeValue(forKey: oldPath) ?? item.identifier
                idByPath[newPath] = movedID
                for p in idByPath.keys.filter({ NTFSPath.hasPrefix($0, oldPrefix) }) {
                    let np = newPath + "/" + p.dropFirst(oldPrefix.count)
                    idByPath[np] = idByPath.removeValue(forKey: p)
                }
            }
        }
        return destinationName
    }

    func reclaimItem(_ item: FSItem) async throws {
        guard let item = item as? NTFSItem else { return }
        try stateLock.withLock {
            if item.reclaimed { return }
            if pendingByPath[item.path] === item {
                let (rc, e) = engine { item.path.withCString { nk_delete(vol, $0) } }
                if rc != 0 {
                    engineQueue.sync { shutdownError = EIO; _ = nk_sync(vol) }
                    throw posix(errno: e)
                }
                pendingByPath[item.path] = nil
                idByPath[item.path] = nil
            }
            // A late reclaim of a replaced item must not evict its successor.
            evictIfCurrent(item)
            item.reclaimed = true
        }
    }

    private func evictIfCurrent(_ item: NTFSItem) {
        stateLock.lock(); defer { stateLock.unlock() }
        if itemByPath[item.path] === item {
            itemByPath[item.path] = nil
            // idByPath is deliberately kept: a path's ID must stay stable for
            // the whole mount (fileIDs, /.vol, hard-link detection). Only
            // delete/rename-over drop entries; rename re-keys them.
            // idByPath grows with every path seen until unmount; persistent
            // MFT-derived IDs remain a separate implementation task.
        }
    }

    // MARK: read / write

    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) async throws -> Int {
        guard let item = item as? NTFSItem else { throw posix(EINVAL) }
        return try withItemPath(item) { currentPath in
            let (n, e) = engine {
                buffer.withUnsafeMutableBytes { raw -> Int64 in
                    currentPath.withCString { path in
                        nk_read(vol, path, Int64(offset), Int64(min(length, raw.count)), raw.baseAddress)
                    }
                }
            }
            guard n >= 0 else { throw posix(errno: e) }
            return Int(n)
        }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        guard let item = item as? NTFSItem else { throw posix(EINVAL) }
        if readOnly { throw posix(EROFS) }
        return try withItemPath(item) { currentPath in
            let (n, e) = engine {
                contents.withUnsafeBytes { raw -> Int64 in
                    currentPath.withCString { path in
                        nk_write(vol, path, Int64(offset), Int64(raw.count), raw.baseAddress)
                    }
                }
            }
            guard n >= 0 else { throw posix(errno: e) }
            return Int(n)
        }
    }

    // MARK: symlinks

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        guard let item = item as? NTFSItem else { throw posix(EINVAL) }
        return try withItemPath(item) { path in
            var buf = [CChar](repeating: 0, count: 4096)
            let (rc, e) = engine { path.withCString { nk_readlink(vol, $0, &buf, 4096) } }
            guard rc == 0 else { throw posix(errno: e, or: EINVAL) }
            return FSFileName(string: String(cString: buf))
        }
    }

    func createSymbolicLink(named name: FSFileName,
                            inDirectory directory: FSItem,
                            attributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName) async throws -> (FSItem, FSFileName) {
        guard let dir = directory as? NTFSItem,
              let linkName = name.string,
              let target = contents.string else { throw posix(EINVAL) }
        if readOnly { throw posix(EROFS) }
        return try stateLock.withLock {
            try requireLive(dir, linked: true)
            let dirPath = dir.path
            let childPath = dir.childPath(linkName)
            do {
                try engineQueue.sync {
                    try NTFSFileOperations.create(volume: vol, parent: dirPath, name: linkName,
                                                  type: .symlink, attributes: attributes, readOnly: readOnly,
                                                  symlinkTarget: target)
                }
            } catch {
                mutateNamespace([dirPath, childPath])
                if (error as NSError).userInfo["DiskFerryRollbackFailed"] as? Bool == true {
                    log.error("symlink create rollback failed at \(childPath, privacy: .public)")
                }
                throw error
            }
            mutateNamespace([dirPath, childPath])
            return (item(path: childPath, kind: .symlink), name)
        }
    }

    // MARK: not yet supported

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem) async throws -> FSFileName {
        throw posix(ENOTSUP)
    }
}

// MARK: - Volume rename

extension NTFSVolume: FSVolume.RenameOperations {

    func setVolumeName(_ name: FSFileName) async throws -> FSFileName {
        guard let label = name.string else { throw posix(EINVAL) }
        if readOnly { throw posix(EROFS) }
        // NTFS labels hold at most 128 UTF-16 units (the bridge fails silently).
        guard label.utf16.count <= 128 else { throw posix(EINVAL) }
        let (rc, e) = engine { label.withCString { nk_set_label(vol, $0) } }
        guard rc == 0 else { throw posix(errno: e) }
        self.name = name
        return name
    }
}

// MARK: - Extended attributes (stored as NTFS alternate data streams)
// Real xattrs on NTFS: no ._ AppleDouble litter, and they round-trip to
// Windows as named streams.

extension NTFSVolume: FSVolume.XattrOperations {

    func xattrs(of item: FSItem) async throws -> [FSFileName] {
        guard let item = item as? NTFSItem else { throw posix(EINVAL) }
        return try withItemPath(item) { path in
            final class NameBox { var names: [String] = [] }
            let box = NameBox()
            let cb: nk_name_cb = { ctx, name in
                guard let ctx, let name else { return 0 }
                Unmanaged<NameBox>.fromOpaque(ctx).takeUnretainedValue()
                    .names.append(String(cString: name))
                return 0
            }
            let (rc, e) = engine {
                path.withCString {
                    nk_xattr_list(vol, $0, cb, Unmanaged.passUnretained(box).toOpaque())
                }
            }
            guard rc == 0 else { throw posix(errno: e) }
            return box.names.map { FSFileName(string: $0) }
        }
    }

    func xattr(named name: FSFileName, of item: FSItem) async throws -> Data {
        guard let item = item as? NTFSItem, let xname = name.string else {
            throw posix(EINVAL)
        }
        return try withItemPath(item) { path in
            // Size query + read under ONE engine hold — a concurrent setXattr
            // between two holds could truncate the read.
            // nil data → the errno to report (ENOATTR when it doesn't exist).
            let (result, err): (Data?, Int32) = engineQueue.sync {
                path.withCString { p -> (Data?, Int32) in
                    xname.withCString { n -> (Data?, Int32) in
                        errno = 0
                        let size = nk_xattr_get(vol, p, n, nil, 0)
                        guard size >= 0 else { return (nil, xattrError(errno)) }
                        // macOS caps xattrs at ~64 KB; a corrupt/huge ADS size must
                        // not drive a giant Data(count:) that kills the extension.
                        // It EXISTS though — say "too big", not "doesn't exist",
                        // or cp/Finder silently drop it.
                        guard size <= 4 << 20 else { return (nil, E2BIG) }
                        if size == 0 { return (Data(), 0) }
                        var data = Data(count: Int(size))
                        errno = 0
                        let got = data.withUnsafeMutableBytes {
                            nk_xattr_get(vol, p, n, $0.baseAddress, Int64($0.count))
                        }
                        guard got >= 0 else { return (nil, xattrError(errno)) }
                        data.removeSubrange(Int(got)..<data.count)
                        return (data, 0)
                    }
                }
            }
            guard let result else { throw posix(err) }
            return result
        }
    }

    func setXattr(named name: FSFileName, to value: Data?, on item: FSItem,
                  policy: FSVolume.SetXattrPolicy) async throws {
        guard let item = item as? NTFSItem, let xname = name.string else {
            throw posix(EINVAL)
        }
        if readOnly { throw posix(EROFS) }
        try withItemPath(item) { path in
            // Existence check + mutation in ONE engine hold — otherwise a
            // concurrent upcall between the two could violate .mustCreate /
            // .mustReplace. `errno`-style POSIX result mapped after the hold.
            let rc: Int32 = value.withUnsafeBytesOrNil { raw in
                engineQueue.sync {
                    path.withCString { p in
                        xname.withCString { n -> Int32 in
                            errno = 0
                            let present = nk_xattr_get(vol, p, n, nil, 0) >= 0
                            if !present && xattrError(errno) != ENOATTR { return xattrError(errno) }
                            switch policy {
                            case .mustCreate where present: return EEXIST
                            case .mustReplace where !present: return ENOATTR
                            case .delete:
                                errno = 0
                                return nk_xattr_remove(vol, p, n) == 0 ? 0 : xattrError(errno)
                            default: break
                            }
                            guard let raw else {   // nil value = delete
                                errno = 0
                                return nk_xattr_remove(vol, p, n) == 0 ? 0 : xattrError(errno)
                            }
                            errno = 0
                            guard nk_xattr_set(vol, p, n, raw.baseAddress,
                                               Int64(raw.count)) == 0 else {
                                return errno != 0 ? errno : EIO   // e.g. ENOSPC
                            }
                            return 0
                        }
                    }
                }
            }
            guard rc == 0 else { throw posix(rc) }
        }
    }

    private func xattrError(_ code: Int32) -> Int32 {
        if code == ENOENT || code == ENOATTR || code == ENODATA { return ENOATTR }
        return code == 0 ? EIO : code
    }
}

// MARK: - Open/Close lifecycle
// Backing links are retained until reclaim rather than each close callback;
// FSKit may hold several open references to one item. No raw handle is cached.

extension NTFSVolume: FSVolume.OpenCloseOperations {

    func openItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        guard let item = item as? NTFSItem else { throw posix(EINVAL) }
        try withItemPath(item) { _ in
            if modes.contains(.write) && readOnly { throw posix(EROFS) }
        }
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        // Nothing retained per open; volume sync/unmount own final flushing.
    }
}

private extension Optional where Wrapped == Data {
    /// Run `body` with the bytes (or nil when self is nil) — lets the xattr
    /// set/delete path do everything inside one closure.
    func withUnsafeBytesOrNil<R>(_ body: (UnsafeRawBufferPointer?) -> R) -> R {
        switch self {
        case .some(let d): return d.withUnsafeBytes { body($0) }
        case .none: return body(nil)
        }
    }
}

/// Box that collects directory entries out of the C callback.
final class DirCollector {
    var items: [(name: String, isDir: Bool, size: Int64)] = []
}

private let nkPreadTrampoline: nk_pread_cb = { ctx, buf, count, offset in
    guard let ctx, let buf else { return -1 }
    let vol = Unmanaged<NTFSVolume>.fromOpaque(ctx).takeUnretainedValue()
    return vol.devicePread(buf, count, offset)
}

private let nkPwriteTrampoline: nk_pwrite_cb = { ctx, buf, count, offset in
    guard let ctx, let buf else { return -1 }
    let vol = Unmanaged<NTFSVolume>.fromOpaque(ctx).takeUnretainedValue()
    return vol.devicePwrite(buf, count, offset)
}

private let dirCollectCallback: nk_dirent_cb = { ctx, entryPtr in
    guard let ctx, let entryPtr else { return 0 }
    let collector = Unmanaged<DirCollector>.fromOpaque(ctx).takeUnretainedValue()
    let entry = entryPtr.pointee
    if let namePtr = entry.name {
        collector.items.append((String(cString: namePtr), entry.is_dir != 0, entry.size))
    }
    return 0
}

private let nkSyncTrampoline: nk_sync_cb = { ctx in
    guard let ctx else { return -1 }
    return Unmanaged<NTFSVolume>.fromOpaque(ctx).takeUnretainedValue().deviceSync()
}
