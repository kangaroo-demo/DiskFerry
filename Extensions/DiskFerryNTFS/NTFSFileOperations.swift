// SPDX-License-Identifier: GPL-2.0-only
// Copyright (c) 2026 DiskFerry contributors

import Foundation
import FSKit

/// Resource-independent operations shared by the real FSKit adapter and image
/// tests. The caller must serialize access to the engine and its namespace.
enum NTFSFileOperations {
    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        guard name.utf16.count <= 255 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }
    }
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
        var times = nk_times()
        if request.isValid(.accessTime) {
            times.valid |= UInt32(NK_TIME_ACCESS)
            times.access = nk_timestamp(seconds: Int64(request.accessTime.tv_sec), nanoseconds: Int32(request.accessTime.tv_nsec))
        }
        if request.isValid(.modifyTime) {
            times.valid |= UInt32(NK_TIME_MODIFY)
            times.modify = nk_timestamp(seconds: Int64(request.modifyTime.tv_sec), nanoseconds: Int32(request.modifyTime.tv_nsec))
        }
        if request.isValid(.birthTime) {
            times.valid |= UInt32(NK_TIME_BIRTH)
            times.birth = nk_timestamp(seconds: Int64(request.birthTime.tv_sec), nanoseconds: Int32(request.birthTime.tv_nsec))
        }
        if times.valid != 0 {
            try checked { path.withCString { nk_set_times_precise(volume, $0, &times) } }
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
        try validateName(name)
        guard type != .symlink || (symlinkTarget != nil && !symlinkTarget!.utf8.contains(0)) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
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
