// SPDX-License-Identifier: GPL-2.0-only
// Copyright (c) 2026 DiskFerry contributors

import Foundation
import FSKit

/// Resource-independent operations shared by the real FSKit adapter and image
/// tests. The caller must serialize access to the engine and its namespace.
enum NTFSFileOperations {
    private static func checked(_ operation: () -> Int32) throws {
        errno = 0
        if operation() != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno == 0 ? EIO : errno))
        }
    }

    /// The complete request must pass NTFSAttributePolicy before this call.
    static func apply(_ request: FSItem.SetAttributesRequest, to path: String,
                      type: FSItem.ItemType, volume: OpaquePointer?, unchanged: FSItem.Attribute) throws {
        if request.isValid(.size), type == .file {
            try checked { path.withCString { nk_truncate(volume, $0, Int64(request.size)) } }
            request.consumedAttributes.insert(.size)
        }
        let atime = request.isValid(.accessTime) ? Int64(request.accessTime.tv_sec) : -1
        let mtime = request.isValid(.modifyTime) ? Int64(request.modifyTime.tv_sec) : -1
        let btime = request.isValid(.birthTime) ? Int64(request.birthTime.tv_sec) : -1
        if atime >= 0 || mtime >= 0 || btime >= 0 {
            try checked { path.withCString { nk_set_times(volume, $0, atime, mtime, btime) } }
            for attribute: FSItem.Attribute in [.accessTime, .modifyTime, .birthTime]
                where request.isValid(attribute) {
                request.consumedAttributes.insert(attribute)
            }
        }
        request.consumedAttributes.formUnion(unchanged)
    }

    static func create(volume: OpaquePointer?, parent: String, name: String,
                       type: FSItem.ItemType, attributes: FSItem.SetAttributesRequest,
                       readOnly: Bool, symlinkTarget: String? = nil) throws {
        guard type == .file || type == .directory || type == .symlink else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))
        }
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.utf8.contains(0),
              type != .symlink || (symlinkTarget != nil && !symlinkTarget!.utf8.contains(0)) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        guard name.utf16.count <= 255 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }
        let defaults = NTFSAttributePolicy.defaults(type: type, uid: getuid(), gid: getgid())
        let unchanged = try NTFSAttributePolicy.validate(attributes, current: defaults,
                                                        readOnly: readOnly, creating: true)
        let path = (parent == "/" ? "" : parent) + "/" + name
        try checked {
            parent.withCString { directory in
                name.withCString { leaf in
                    switch type {
                    case .directory: return nk_mkdir(volume, directory, leaf)
                    case .symlink:
                        return symlinkTarget!.withCString { nk_create_symlink(volume, directory, leaf, $0) }
                    default: return nk_create(volume, directory, leaf)
                    }
                }
            }
        }
        do {
            try apply(attributes, to: path, type: type, volume: volume, unchanged: unchanged)
        } catch {
            // Only remove an item whose create returned success. In particular,
            // EEXIST above must never delete somebody else's existing file.
            // A device fault freezes writes, so rollback may fail and must be
            // reported while the session's dirty marker remains in place.
            let original = error as NSError
            let removed = path.withCString { nk_delete(volume, $0) }
            attributes.consumedAttributes = []
            if removed != 0 {
                throw NSError(domain: original.domain, code: original.code,
                              userInfo: [NSUnderlyingErrorKey: original, "DiskFerryRollbackFailed": true])
            }
            throw original
        }
    }
}
