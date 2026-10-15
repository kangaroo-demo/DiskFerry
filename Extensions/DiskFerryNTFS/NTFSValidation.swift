// SPDX-License-Identifier: GPL-2.0-only
// Copyright (c) 2026 DiskFerry contributors

import Foundation
import FSKit

/// Validate all requested changes before the first disk mutation. Unsupported
/// ACL/flag operations must never report success or partially truncate a file.
enum NTFSAttributePolicy {
    static func validate(_ request: FSItem.SetAttributesRequest,
                         current: FSItem.Attributes, readOnly: Bool) throws -> FSItem.Attribute {
        func reject(_ code: Int32) throws -> Never {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        if readOnly { try reject(EROFS) }
        let unsupported: [FSItem.Attribute] = [.type, .linkCount, .allocSize, .fileID, .parentID,
            .changeTime, .backupTime, .addedTime, .supportsLimitedXAttrs, .inhibitKernelOffloadedIO]
        if unsupported.contains(where: { request.isValid($0) }) { try reject(ENOTSUP) }
        var unchanged: FSItem.Attribute = []
        if request.isValid(.mode) {
            guard request.mode & 0o7777 == current.mode & 0o7777 else { try reject(ENOTSUP) }
            unchanged.insert(.mode)
        }
        if request.isValid(.uid) {
            guard request.uid == current.uid else { try reject(ENOTSUP) }
            unchanged.insert(.uid)
        }
        if request.isValid(.gid) {
            guard request.gid == current.gid else { try reject(ENOTSUP) }
            unchanged.insert(.gid)
        }
        if request.isValid(.flags) {
            guard request.flags == current.flags else { try reject(ENOTSUP) }
            unchanged.insert(.flags)
        }
        if request.isValid(.size) {
            guard current.type == .file else { try reject(EINVAL) }
            guard request.size <= UInt64(Int64.max) else { try reject(EFBIG) }
        }
        let times: [(FSItem.Attribute, timespec)] = [(.accessTime, request.accessTime),
            (.modifyTime, request.modifyTime), (.birthTime, request.birthTime)]
        for (attribute, time) in times where request.isValid(attribute) {
            // The bridge currently stores whole seconds; reject dates outside
            // its sentinel/range contract rather than ignoring or overflowing.
            guard time.tv_sec >= 0, time.tv_sec <= Int64.max / 10_000_000 - 11_644_473_600,
                  (0..<1_000_000_000).contains(time.tv_nsec) else { try reject(EINVAL) }
        }
        return unchanged
    }
}

/// Resource geometry is untrusted and must be checked before Int64 conversion,
/// multiplication, division or aligned scratch-buffer allocation.
struct NTFSResourceGeometry {
    let blockSize: Int64
    let bytes: Int64

    init(blockSize: UInt64, blockCount: UInt64) throws {
        guard (512...65536).contains(blockSize), blockSize.nonzeroBitCount == 1,
              blockCount > 0, blockCount <= UInt64(Int64.max) / blockSize else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        self.blockSize = Int64(blockSize)
        bytes = Int64(blockSize * blockCount)
    }
}
