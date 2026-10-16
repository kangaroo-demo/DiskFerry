// SPDX-License-Identifier: GPL-2.0-only
// Copyright (c) 2026 DiskFerry contributors

import CryptoKit
import ExtensionFoundation
import Foundation
import FSKit

@main
struct DiskFerryNTFSExtension: UnaryFileSystemExtension {
    let fileSystem = DiskFerryFileSystem()
}

/// Experimental module. It has no automatic media matching until mounting,
/// health checks and policy handoff have been qualified on real resources.
final class DiskFerryFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    private let lock = NSLock()
    private var loadedResource: FSBlockDeviceResource?
    private weak var loadedVolume: NTFSVolume?
    private let checkQueue = DispatchQueue(label: "dev.diskferry.ntfs.check")

    private func identifier(_ boot: NTFSBootSector) -> UUID {
        // All serial bits enter the digest before setting the UUID variant;
        // setting UUID version bits directly in the serial would lose bits.
        let digest = SHA256.hash(data: Data("dev.diskferry.ntfs:\(boot.volumeSerial)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80 // application-defined UUID v8
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func probeResource(resource: FSResource) async throws -> FSProbeResult {
        guard let block = resource as? FSBlockDeviceResource else { return .notRecognized }
        do {
            let boot = try FSKitNTFSProbe.inspect(block)
            return .usable(name: "NTFS", containerID: FSContainerIdentifier(uuid: identifier(boot)))
        } catch NTFSProbeError.notNTFS {
            return .notRecognized
        }
    }

    func loadResource(resource: FSResource, options: FSTaskOptions) async throws -> FSVolume {
        guard let block = resource as? FSBlockDeviceResource else { throw posix(EINVAL) }
        let boot = try FSKitNTFSProbe.inspect(block)
        // The integration initially exposes read-only mounting. This guard
        // will be replaced by an authenticated per-resource policy handoff
        // once both engine and FSKit write paths have passed qualification.
        let volume = NTFSVolume(resource: block, volumeName: FSFileName(string: "NTFS"),
                                volumeID: .init(uuid: identifier(boot)), readOnly: true)
        lock.withLock { loadedResource = block; loadedVolume = volume }
        containerStatus = .ready
        return volume
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {
        lock.withLock { loadedResource = nil; loadedVolume = nil }
    }

    private func posix(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

extension DiskFerryFileSystem: FSManageableResourceMaintenanceOperations {
    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let (resource, volume) = lock.withLock { (loadedResource, loadedVolume) }
        checkQueue.async {
            var error: Error?
            defer {
                progress.completedUnitCount = 1
                task.didComplete(error: error)
            }
            guard let resource, !resource.isRevoked, volume?.isEngineOpen != true else {
                error = self.posix(resource == nil ? ENXIO : EBUSY)
                return
            }
            let adapter: ReadOnlyCheckIO
            do { adapter = try ReadOnlyCheckIO(resource) }
            catch let failure { error = failure; return }
            var io = nk_io(ctx: Unmanaged.passUnretained(adapter).toOpaque(),
                           pread: checkRead, pwrite: nil, sync: nil,
                           size: adapter.size, readonly: 1)
            let result = withExtendedLifetime(adapter) { nk_fsck(&io, 0, nil, 0) }
            if result != 0 { error = self.posix(result == 1 || result == -2 ? EROFS : EIO) }
        }
        return progress
    }

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        throw posix(ENOTSUP)
    }
}

private final class ReadOnlyCheckIO {
    let resource: FSBlockDeviceResource
    let size: Int64

    init(_ resource: FSBlockDeviceResource) throws {
        let geometry = try NTFSResourceGeometry(blockSize: resource.blockSize, blockCount: resource.blockCount)
        self.resource = resource
        size = geometry.bytes
    }

    func read(_ destination: UnsafeMutableRawPointer, count: Int64, offset: Int64) -> Int64 {
        let block = Int64(resource.blockSize)
        guard !resource.isRevoked, offset >= 0, count >= 0, offset <= size, count <= size - offset,
              count <= 16 * 1024 * 1024 else { return -1 }
        if count == 0 { return 0 }
        let start = offset / block * block
        let end = min(size, ((offset + count - 1) / block + 1) * block)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Int(end - start), alignment: Int(block))
        defer { buffer.deallocate() }
        do {
            let read = try resource.read(into: buffer, startingAt: start, length: buffer.count)
            guard read == buffer.count else { return -1 }
            memcpy(destination, buffer.baseAddress!.advanced(by: Int(offset - start)), Int(count))
            return count
        } catch { return -1 }
    }
}

private let checkRead: nk_pread_cb = { context, buffer, count, offset in
    guard let context, let buffer else { return -1 }
    return Unmanaged<ReadOnlyCheckIO>.fromOpaque(context).takeUnretainedValue()
        .read(buffer, count: count, offset: offset)
}
