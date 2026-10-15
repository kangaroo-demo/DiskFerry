import Darwin
import Foundation
import FSKit
import XCTest

final class ImageDevice {
    var fd: Int32
    var writes = 0
    var failAfterWrites: Int?

    init(path: String) throws {
        fd = Darwin.open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard ftruncate(fd, 64 * 1024 * 1024) == 0 else {
            let code = errno
            Darwin.close(fd)
            fd = -1
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }
}

private let imageRead: nk_pread_cb = { context, buffer, count, offset in
    guard let context, let buffer else { return -1 }
    let device = Unmanaged<ImageDevice>.fromOpaque(context).takeUnretainedValue()
    return Int64(pread(device.fd, buffer, Int(count), off_t(offset)))
}

private let imageWrite: nk_pwrite_cb = { context, buffer, count, offset in
    guard let context, let buffer else { return -1 }
    let device = Unmanaged<ImageDevice>.fromOpaque(context).takeUnretainedValue()
    device.writes += 1
    if let limit = device.failAfterWrites, device.writes > limit { errno = EIO; return -1 }
    return Int64(pwrite(device.fd, buffer, Int(count), off_t(offset)))
}

private let imageSync: nk_sync_cb = { context in
    guard let context else { return -1 }
    return fsync(Unmanaged<ImageDevice>.fromOpaque(context).takeUnretainedValue().fd)
}

final class ImageSession {
    let directory: URL
    let device: ImageDevice
    var volume: OpaquePointer?

    init(readOnly: Bool = false) throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        directory = root.appendingPathComponent(".build/fskit-adapter-tests/case-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appendingPathComponent("disposable.ntfs")
        device = try ImageDevice(path: image.path)
        let formatter = Process()
        formatter.executableURL = root.appendingPathComponent(".build/vendor/ntfs-3g-2026.9.28/ntfsprogs/mkntfs")
        formatter.arguments = ["-F", "-Q", "-L", "DISKFERRY_TEST", image.path]
        formatter.standardOutput = FileHandle.nullDevice
        formatter.standardError = FileHandle.nullDevice
        try formatter.run()
        formatter.waitUntilExit()
        guard formatter.terminationStatus == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
        try mount(readOnly: readOnly)
    }

    func mount(readOnly: Bool) throws {
        var io = nk_io(ctx: Unmanaged.passUnretained(device).toOpaque(), pread: imageRead,
                       pwrite: imageWrite, sync: imageSync, size: 64 * 1024 * 1024, readonly: readOnly ? 1 : 0)
        volume = nk_mount_io(&io, nil, 0)
        guard volume != nil else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    @discardableResult func close() -> Int32 {
        guard let handle = volume else { return 0 }
        volume = nil
        return nk_umount(handle)
    }

    func stat(_ path: String) throws -> nk_stat {
        var result = nk_stat()
        try path.withCString { pointer in
            guard nk_stat_path(volume, pointer, &result) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        return result
    }

    func create(_ name: String, type: FSItem.ItemType = .file,
                request: FSItem.SetAttributesRequest = FSItem.SetAttributesRequest(),
                readOnly: Bool = false, target: String? = nil) throws {
        try NTFSFileOperations.create(volume: volume, parent: "/", name: name, type: type,
                                      attributes: request, readOnly: readOnly, symlinkTarget: target)
    }

    deinit {
        close()
        try? FileManager.default.removeItem(at: directory)
    }
}

@objcMembers final class CreationTests: XCTestCase {
    private func expectError(_ code: Int32, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(code))
        }
    }

    func testFileSizeTimesAndConsumedAttributesPersist() throws {
        let image = try ImageSession()
        let request = FSItem.SetAttributesRequest()
        request.type = .file
        request.mode = 0o644
        request.uid = getuid()
        request.gid = getgid()
        request.size = 4097
        request.accessTime = timespec(tv_sec: 1_500_000_001, tv_nsec: 0)
        request.modifyTime = timespec(tv_sec: 1_500_000_002, tv_nsec: 0)
        request.birthTime = timespec(tv_sec: 1_500_000_003, tv_nsec: 0)
        try image.create("创建 😀.bin", request: request)
        XCTAssertEqual(request.consumedAttributes, [.type, .mode, .uid, .gid, .size, .accessTime, .modifyTime, .birthTime])
        XCTAssertEqual(image.close(), 0)
        try image.mount(readOnly: true)
        let attributes = try image.stat("/创建 😀.bin")
        XCTAssertEqual(attributes.size, 4097)
        XCTAssertEqual(attributes.atime, 1_500_000_001)
        XCTAssertEqual(attributes.mtime, 1_500_000_002)
        XCTAssertEqual(attributes.btime, 1_500_000_003)
        var bytes = [UInt8](repeating: 255, count: 4097)
        let count = "/创建 😀.bin".withCString { nk_read(image.volume, $0, 0, 4097, &bytes) }
        XCTAssertEqual(count, 4097)
        XCTAssertTrue(bytes.allSatisfy { $0 == 0 })
    }

    func testDirectoryCreationAppliesTimes() throws {
        let image = try ImageSession()
        let request = FSItem.SetAttributesRequest()
        request.mode = 0o755
        request.size = UInt64.max
        request.birthTime = timespec(tv_sec: 123456, tv_nsec: 0)
        try image.create("directory", type: .directory, request: request)
        XCTAssertEqual(request.consumedAttributes, [.mode, .birthTime])
        XCTAssertEqual(image.close(), 0)
        try image.mount(readOnly: true)
        let attributes = try image.stat("/directory")
        XCTAssertEqual(attributes.is_dir, 1)
        XCTAssertEqual(attributes.btime, 123456)
    }

    func testSymlinkCreationAppliesTimesWithoutChangingTarget() throws {
        let image = try ImageSession()
        let request = FSItem.SetAttributesRequest()
        request.size = UInt64.max
        request.modifyTime = timespec(tv_sec: 123456, tv_nsec: 0)
        try image.create("link", type: .symlink, request: request, target: "/目录/target")
        XCTAssertEqual(request.consumedAttributes, [.modifyTime])
        XCTAssertEqual(image.close(), 0)
        try image.mount(readOnly: true)
        XCTAssertEqual(try image.stat("/link").mtime, 123456)
        var target = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(nk_readlink(image.volume, "/link", &target, target.count), 0)
        XCTAssertEqual(String(cString: target), "/目录/target")
    }

    func testInvalidAttributesFailBeforeCreationOrAnyDeviceWrite() throws {
        let image = try ImageSession()
        let writes = image.device.writes
        for index in 0..<5 {
            let request = FSItem.SetAttributesRequest()
            let code: Int32
            switch index {
            case 0: request.mode = 0o600; code = ENOTSUP
            case 1: request.size = UInt64.max; code = EFBIG
            case 2: request.modifyTime = timespec(tv_sec: -11_644_473_601, tv_nsec: 0); code = EINVAL
            case 3: request.type = .directory; code = EINVAL
            default: request.flags = 2; code = ENOTSUP
            }
            expectError(code) { try image.create("rejected", request: request) }
            XCTAssertEqual(request.consumedAttributes, [])
            XCTAssertEqual(image.device.writes, writes)
            XCTAssertThrowsError(try image.stat("/rejected"))
        }
    }

    func testExistingDestinationIsNotTruncatedOrRemoved() throws {
        let image = try ImageSession()
        try image.create("existing")
        XCTAssertEqual(nk_write(image.volume, "/existing", 0, 4, "KEEP"), 4)
        let request = FSItem.SetAttributesRequest()
        request.size = 0
        expectError(EEXIST) { try image.create("existing", request: request) }
        XCTAssertEqual(request.consumedAttributes, [])
        XCTAssertEqual(image.close(), 0)
        try image.mount(readOnly: true)
        var data = [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(nk_read(image.volume, "/existing", 0, 4, &data), 4)
        XCTAssertEqual(data, Array("KEEP".utf8))
    }

    func testReadOnlyPolicyAndEngineBothRefuseCreation() throws {
        let image = try ImageSession(readOnly: true)
        expectError(EROFS) { try image.create("rejected", readOnly: true) }
        expectError(EROFS) { try image.create("also-rejected", readOnly: false) }
        XCTAssertEqual(image.device.writes, 0)
        XCTAssertThrowsError(try image.stat("/rejected"))
        XCTAssertThrowsError(try image.stat("/also-rejected"))
    }

    func testAttributeWriteFailureKeepsSessionDirtyAndReportsRollbackFailure() throws {
        let control = try ImageSession()
        let initial = control.device.writes
        try control.create("configured")
        let creationWrites = control.device.writes - initial
        XCTAssertGreaterThan(creationWrites, 0)
        XCTAssertEqual(control.close(), 0)

        let image = try ImageSession()
        image.device.failAfterWrites = image.device.writes + creationWrites
        let request = FSItem.SetAttributesRequest()
        request.modifyTime = timespec(tv_sec: 123456, tv_nsec: 0)
        XCTAssertThrowsError(try image.create("configured", request: request)) { error in
            XCTAssertEqual((error as NSError).code, Int(EIO))
            XCTAssertEqual((error as NSError).userInfo["DiskFerryRollbackFailed"] as? Bool, true)
        }
        XCTAssertEqual(request.consumedAttributes, [])
        image.device.failAfterWrites = nil
        XCTAssertEqual(image.close(), -1)
        try image.mount(readOnly: true)
        XCTAssertEqual(nk_is_dirty(image.volume), 1)
    }

    func testInvalidLeafNamesCannotCreateUnreachableEntries() throws {
        let image = try ImageSession()
        let writes = image.device.writes
        for name in ["", ".", "..", "a/b", "a\0b"] {
            expectError(EINVAL) { try image.create(name) }
            XCTAssertEqual(image.device.writes, writes)
        }
        expectError(ENAMETOOLONG) { try image.create(String(repeating: "😀", count: 128)) }
        XCTAssertEqual(image.device.writes, writes)
    }
}
