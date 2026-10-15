import Darwin
import Foundation
import FSKit
import XCTest

/// Regular-file transport for exercising the production volume methods. The
/// metadata methods use pread/pwrite/fsync, not a simulated FSKit buffer cache.
final class ImageBlockIO: NTFSBlockIO {
    let device: ImageDevice
    let blockSize: UInt64 = 512
    let blockCount: UInt64 = 64 * 1024 * 1024 / 512
    private let lock = NSLock()
    private var revoked = false
    private var readFailure = false
    private var writeFailure = false
    private var writeLimit: Int?
    private var writes = 0
    var isRevoked: Bool { get { lock.withLock { revoked } } set { lock.withLock { revoked = newValue } } }
    var failReads: Bool { get { lock.withLock { readFailure } } set { lock.withLock { readFailure = newValue } } }
    var failWrites: Bool { get { lock.withLock { writeFailure } } set { lock.withLock { writeFailure = newValue } } }
    var failAfterWrites: Int? { get { lock.withLock { writeLimit } } set { lock.withLock { writeLimit = newValue } } }
    var writeCount: Int { lock.withLock { writes } }

    init(_ device: ImageDevice) { self.device = device }

    func read(into buffer: UnsafeMutableRawBufferPointer, startingAt offset: off_t, length: Int) throws -> Int {
        if isRevoked || failReads { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
        let result = pread(device.fd, buffer.baseAddress, length, offset)
        guard result >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return result
    }

    func write(from buffer: UnsafeRawBufferPointer, startingAt offset: off_t, length: Int) throws -> Int {
        let failed = lock.withLock {
            writes += 1
            return revoked || writeFailure || (writeLimit.map { writes > $0 } ?? false)
        }
        if failed { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
        let result = pwrite(device.fd, buffer.baseAddress, length, offset)
        guard result >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return result
    }

    func metadataRead(into buffer: UnsafeMutableRawBufferPointer, startingAt offset: off_t, length: Int) throws {
        guard try read(into: buffer, startingAt: offset, length: length) == length else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
    }

    func metadataWrite(from buffer: UnsafeRawBufferPointer, startingAt offset: off_t, length: Int) throws {
        guard try write(from: buffer, startingAt: offset, length: length) == length else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
    }

    func metadataFlush() throws {
        guard fsync(device.fd) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

private final class VolumeImage {
    let image: ImageSession
    let transport: ImageBlockIO
    let volume: NTFSVolume
    let root: FSItem

    init() throws {
        image = try ImageSession()
        guard image.close() == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
        transport = ImageBlockIO(image.device)
        volume = NTFSVolume(resource: transport, volumeName: FSFileName(string: "TEST"),
                            volumeID: .init(uuid: UUID()), readOnly: false)
        root = try volume.activateVolume()
    }

    func create(_ name: String, type: FSItem.ItemType = .file, parent: FSItem? = nil) async throws -> FSItem {
        try await volume.createItem(named: FSFileName(string: name), type: type, inDirectory: parent ?? root,
                                    attributes: FSItem.SetAttributesRequest()).0
    }

    func rename(_ item: FSItem, from old: String, to new: String, over: FSItem? = nil) async throws {
        _ = try await volume.renameItem(item, inDirectory: root, named: FSFileName(string: old),
                                        to: FSFileName(string: new), inDirectory: root, overItem: over)
    }

    func contentsAfterClose(_ path: String) throws -> Data {
        guard !volume.isEngineOpen else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY)) }
        if image.volume == nil { try image.mount(readOnly: true) }
        let attributes = try image.stat(path)
        guard attributes.size >= 0, attributes.size <= 1 << 20 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EFBIG))
        }
        var data = Data(count: Int(attributes.size))
        let count = data.withUnsafeMutableBytes { bytes in
            path.withCString { nk_read(image.volume, $0, 0, Int64(bytes.count), bytes.baseAddress) }
        }
        guard count == attributes.size else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
        return data
    }

    deinit { volume.finishVolume() }
}

private final class AsyncTestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    func set(_ error: Error) { lock.withLock { self.error = error } }
    func check() throws { if let error = lock.withLock({ error }) { throw error } }
}

@objcMembers final class VolumeTests: XCTestCase {
    private func expectError(_ code: Int32, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("Expected POSIX error \(code)")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(code))
        }
    }
    private func runAsync(_ body: @escaping () async throws -> Void) throws {
        let completed = expectation(description: "volume image operation")
        let result = AsyncTestResult()
        let task = Task.detached {
            do { try await body() } catch { result.set(error) }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 20)
        task.cancel()
        try result.check()
    }

    func testSubsecondCreationAndSetTimesPersistAtNTFSPrecision() throws {
        try runAsync {
            let session = try VolumeImage()
            let request = FSItem.SetAttributesRequest()
            request.accessTime = timespec(tv_sec: 1_500_000_001, tv_nsec: 123_456_789)
            request.modifyTime = timespec(tv_sec: 1_500_000_002, tv_nsec: 987_654_321)
            request.birthTime = timespec(tv_sec: 1_500_000_003, tv_nsec: 1_234_599)
            let (file, _) = try await session.volume.createItem(named: FSFileName(string: "precise"), type: .file,
                inDirectory: session.root, attributes: request)
            var attributes = try await session.volume.attributes(FSItem.GetAttributesRequest(), of: file)
            XCTAssertEqual(attributes.accessTime.tv_nsec, 123_456_700)
            XCTAssertEqual(attributes.modifyTime.tv_nsec, 987_654_300)
            XCTAssertEqual(attributes.birthTime.tv_nsec, 1_234_500)
            let update = FSItem.SetAttributesRequest()
            update.modifyTime = timespec(tv_sec: 1_600_000_001, tv_nsec: 999_999_999)
            attributes = try await session.volume.setAttributes(update, on: file)
            XCTAssertEqual(attributes.modifyTime.tv_sec, 1_600_000_001)
            XCTAssertEqual(attributes.modifyTime.tv_nsec, 999_999_900)
            XCTAssertEqual(attributes.accessTime.tv_nsec, 123_456_700)
            XCTAssertEqual(attributes.birthTime.tv_nsec, 1_234_500)
            XCTAssertEqual(update.consumedAttributes, [.modifyTime])
            XCTAssertEqual(session.volume.finishVolume(), 0)
            let reopened = NTFSVolume(resource: session.transport, volumeName: FSFileName(string: "TEST"),
                                      volumeID: .init(uuid: UUID()), readOnly: true)
            defer { reopened.finishVolume() }
            let root = try reopened.activateVolume()
            let (found, _) = try await reopened.lookupItem(named: FSFileName(string: "precise"), inDirectory: root)
            attributes = try await reopened.attributes(FSItem.GetAttributesRequest(), of: found)
            XCTAssertEqual(attributes.modifyTime.tv_sec, 1_600_000_001)
            XCTAssertEqual(attributes.modifyTime.tv_nsec, 999_999_900)
            XCTAssertEqual(attributes.accessTime.tv_nsec, 123_456_700)
            XCTAssertEqual(attributes.birthTime.tv_nsec, 1_234_500)
        }
    }

    func testPreUnixEpochTimesAndNTFSEpochArePreserved() throws {
        try runAsync {
            let session = try VolumeImage()
            let request = FSItem.SetAttributesRequest()
            request.accessTime = timespec(tv_sec: -1, tv_nsec: 123_456_789)
            request.modifyTime = timespec(tv_sec: -123_456_789, tv_nsec: 987_654_321)
            request.birthTime = timespec(tv_sec: -11_644_473_600, tv_nsec: 0)
            let (file, _) = try await session.volume.createItem(named: FSFileName(string: "old"), type: .file,
                inDirectory: session.root, attributes: request)
            let attributes = try await session.volume.attributes(FSItem.GetAttributesRequest(), of: file)
            XCTAssertEqual(attributes.accessTime.tv_sec, -1)
            XCTAssertEqual(attributes.accessTime.tv_nsec, 123_456_700)
            XCTAssertEqual(attributes.modifyTime.tv_sec, -123_456_789)
            XCTAssertEqual(attributes.modifyTime.tv_nsec, 987_654_300)
            XCTAssertEqual(attributes.birthTime.tv_sec, -11_644_473_600)
            XCTAssertEqual(attributes.birthTime.tv_nsec, 0)
            XCTAssertEqual(request.consumedAttributes, [.accessTime, .modifyTime, .birthTime])
            XCTAssertEqual(session.volume.finishVolume(), 0)
            try session.image.mount(readOnly: true)
            let stored = try session.image.stat("/old")
            XCTAssertEqual(stored.atime, -1)
            XCTAssertEqual(stored.atime_nsec, 123_456_700)
            XCTAssertEqual(stored.mtime, -123_456_789)
            XCTAssertEqual(stored.mtime_nsec, 987_654_300)
            XCTAssertEqual(stored.btime, -11_644_473_600)
        }
    }

    func testInvalidTimeRejectsWholeSetBeforeTruncateOrTimeMutation() throws {
        try runAsync {
            let session = try VolumeImage()
            let file = try await session.create("keep")
            _ = try await session.volume.write(contents: Data("KEEP".utf8), to: file, at: 0)
            let before = try await session.volume.attributes(FSItem.GetAttributesRequest(), of: file)
            let writes = session.transport.writeCount
            for date in [timespec(tv_sec: -11_644_473_601, tv_nsec: 0),
                         timespec(tv_sec: 910_692_730_085, tv_nsec: 477_580_800),
                         timespec(tv_sec: 0, tv_nsec: Int.max)] {
                let request = FSItem.SetAttributesRequest()
                request.size = 0
                request.accessTime = timespec(tv_sec: 123, tv_nsec: 456)
                request.modifyTime = date
                await self.expectError(EINVAL) { _ = try await session.volume.setAttributes(request, on: file) }
                XCTAssertEqual(request.consumedAttributes, [])
            }
            let after = try await session.volume.attributes(FSItem.GetAttributesRequest(), of: file)
            XCTAssertEqual(after.size, 4)
            XCTAssertEqual(after.accessTime.tv_sec, before.accessTime.tv_sec)
            XCTAssertEqual(after.accessTime.tv_nsec, before.accessTime.tv_nsec)
            XCTAssertEqual(session.transport.writeCount, writes)
            XCTAssertEqual(session.volume.finishVolume(), 0)
            XCTAssertEqual(try session.contentsAfterClose("/keep"), Data("KEEP".utf8))
        }
    }

    func testTimestampRangeEdgesRoundTripWithoutOverflow() throws {
        try runAsync {
            let session = try VolumeImage()
            let dates = [timespec(tv_sec: -11_644_473_600, tv_nsec: 99),
                         timespec(tv_sec: -1, tv_nsec: 999_999_999),
                         timespec(tv_sec: 0, tv_nsec: 0),
                         timespec(tv_sec: 910_692_730_085, tv_nsec: 477_580_799)]
            for (index, date) in dates.enumerated() {
                let request = FSItem.SetAttributesRequest()
                request.modifyTime = date
                let (file, _) = try await session.volume.createItem(named: FSFileName(string: "edge-\(index)"), type: .file,
                    inDirectory: session.root, attributes: request)
                let actual = try await session.volume.attributes(FSItem.GetAttributesRequest(), of: file)
                XCTAssertEqual(actual.modifyTime.tv_sec, date.tv_sec)
                XCTAssertEqual(actual.modifyTime.tv_nsec, date.tv_nsec / 100 * 100)
            }
            XCTAssertEqual(session.volume.finishVolume(), 0)
            try session.image.mount(readOnly: true)
            for (index, date) in dates.enumerated() {
                let stored = try session.image.stat("/edge-\(index)")
                XCTAssertEqual(stored.mtime, Int64(date.tv_sec))
                XCTAssertEqual(stored.mtime_nsec, Int32(date.tv_nsec / 100 * 100))
            }
        }
    }

    func testCanonicallyEquivalentNamesRetainSeparateObjectsAndData() throws {
        try runAsync {
            let session = try VolumeImage()
            let composed = "Caf\u{e9}"
            let decomposed = "Cafe\u{301}"
            let first = try await session.create(composed, type: .directory)
            let second = try await session.create(decomposed, type: .directory)
            XCTAssertFalse(first === second, "NTFS stores these UTF-16 names separately")
            let firstChild = try await session.create("child", parent: first)
            let secondChild = try await session.create("child", parent: second)
            XCTAssertFalse(firstChild === secondChild)
            _ = try await session.volume.write(contents: Data("FIRST".utf8), to: firstChild, at: 0)
            _ = try await session.volume.write(contents: Data("SECOND".utf8), to: secondChild, at: 0)
            try await session.rename(first, from: composed, to: "moved")
            _ = try await session.volume.write(contents: Data("OTHER".utf8), to: secondChild, at: 0)
            XCTAssertEqual(Data((secondChild as! NTFSItem).path.utf8), Data(("/" + decomposed + "/child").utf8))
            XCTAssertEqual(session.volume.finishVolume(), 0)
            XCTAssertEqual(try session.contentsAfterClose("/moved/child"), Data("FIRST".utf8))
            XCTAssertEqual(try session.contentsAfterClose("/" + decomposed + "/child"), Data("OTHERD".utf8))
        }
    }

    func testCaseLookupReturnsActualSpellingAndOneCachedObject() throws {
        try runAsync {
            let session = try VolumeImage()
            let original = try await session.create("R\u{e9}sum\u{e9}.TXT")
            let (found, name) = try await session.volume.lookupItem(named: FSFileName(string: "R\u{c9}SUM\u{c9}.txt"),
                                                                    inDirectory: session.root)
            XCTAssertTrue(found === original)
            XCTAssertEqual(Data((name.string ?? "").utf8), Data("R\u{e9}sum\u{e9}.TXT".utf8))
            await self.expectError(EEXIST) { _ = try await session.create("r\u{e9}sum\u{e9}.txt") }
            try await session.volume.removeItem(found, named: FSFileName(string: "R\u{c9}SUM\u{c9}.txt"),
                                                 fromDirectory: session.root)
            let privateName = ((original as! NTFSItem).path as NSString).lastPathComponent.uppercased()
            await self.expectError(ENOENT) {
                _ = try await session.volume.lookupItem(named: FSFileName(string: privateName), inDirectory: session.root)
            }
            XCTAssertEqual(session.volume.finishVolume(), 0)
        }
    }

    func testCaseOnlyRenamePreservesFileAndCachedChildren() throws {
        try runAsync {
            let session = try VolumeImage()
            let directory = try await session.create("D\u{e9}tails", type: .directory)
            let child = try await session.create("Mixed.txt", parent: directory)
            _ = try await session.volume.write(contents: Data("CONTENTS".utf8), to: child, at: 0)
            _ = try await session.volume.renameItem(directory, inDirectory: session.root,
                named: FSFileName(string: "D\u{c9}TAILS"), to: FSFileName(string: "D\u{c9}TAILS"),
                inDirectory: session.root, overItem: directory)
            _ = try await session.volume.renameItem(child, inDirectory: directory,
                named: FSFileName(string: "mixed.TXT"), to: FSFileName(string: "MIXED.TXT"),
                inDirectory: directory, overItem: child)
            let (found, name) = try await session.volume.lookupItem(named: FSFileName(string: "mixed.txt"), inDirectory: directory)
            XCTAssertTrue(found === child)
            XCTAssertEqual(name.string, "MIXED.TXT")
            XCTAssertEqual(session.volume.finishVolume(), 0)
            XCTAssertEqual(try session.contentsAfterClose("/D\u{c9}TAILS/MIXED.TXT"), Data("CONTENTS".utf8))
            XCTAssertThrowsError(try session.image.stat("/D\u{e9}tails/Mixed.txt"))
        }
    }

    func testRenameOverUsingDifferentCaseKeepsVictimAndSuccessorSeparate() throws {
        try runAsync {
            let session = try VolumeImage()
            let source = try await session.create("Source")
            let victim = try await session.create("Target")
            _ = try await session.volume.write(contents: Data("SOURCE".utf8), to: source, at: 0)
            _ = try await session.volume.write(contents: Data("VICTIM".utf8), to: victim, at: 0)
            try await session.rename(source, from: "SOURCE", to: "TARGET", over: victim)
            let (found, name) = try await session.volume.lookupItem(named: FSFileName(string: "target"), inDirectory: session.root)
            XCTAssertTrue(found === source)
            XCTAssertEqual(name.string, "TARGET")
            _ = try await session.volume.write(contents: Data("OLD CHANGED".utf8), to: victim, at: 0)
            await self.expectError(EEXIST) { _ = try await session.create("Target") }
            try await session.volume.reclaimItem(victim)
            let (after, _) = try await session.volume.lookupItem(named: FSFileName(string: "Target"), inDirectory: session.root)
            XCTAssertTrue(after === source)
            XCTAssertEqual(session.volume.finishVolume(), 0)
            XCTAssertEqual(try session.contentsAfterClose("/TARGET"), Data("SOURCE".utf8))
        }
    }

    func testRemovedOpenItemCannotAliasARecreatedPath() throws {
        try runAsync {
            let image = try ImageSession()
            XCTAssertEqual(image.close(), 0)
            let volume = NTFSVolume(resource: ImageBlockIO(image.device), volumeName: FSFileName(string: "TEST"),
                                    volumeID: .init(uuid: UUID()), readOnly: false)
            defer { volume.finishVolume() }
            let root = try volume.activateVolume()
            let name = FSFileName(string: "same.bin")
            let (old, _) = try await volume.createItem(named: name, type: .file, inDirectory: root,
                                                       attributes: FSItem.SetAttributesRequest())
            _ = try await volume.write(contents: Data("OLD DATA".utf8), to: old, at: 0)
            try await volume.removeItem(old, named: name, fromDirectory: root)
            let oldAttributes = try await volume.attributes(FSItem.GetAttributesRequest(), of: old)
            XCTAssertEqual(oldAttributes.linkCount, 0)
            let backingName = ((old as! NTFSItem).path as NSString).lastPathComponent
            await self.expectError(ENOENT) {
                _ = try await volume.lookupItem(named: FSFileName(string: backingName), inDirectory: root)
            }
            XCTAssertTrue(try volume.visibleEntries(in: root as! NTFSItem).isEmpty)
            let (new, _) = try await volume.createItem(named: name, type: .file, inDirectory: root,
                                                       attributes: FSItem.SetAttributesRequest())
            _ = try await volume.write(contents: Data("NEW".utf8), to: new, at: 0)
            _ = try await volume.write(contents: Data("OLD AGAIN".utf8), to: old, at: 0)
            let attributes = try await volume.attributes(FSItem.GetAttributesRequest(), of: new)
            XCTAssertEqual(attributes.size, 3, "Old handle overwrote the recreated file")
            try await volume.reclaimItem(old)
            await self.expectError(ESTALE) { _ = try await volume.write(contents: Data("BAD".utf8), to: old, at: 0) }
            await volume.unmount()
            try image.mount(readOnly: true)
            var data = [UInt8](repeating: 0, count: 32)
            let count = nk_read(image.volume, "/same.bin", 0, 32, &data)
            XCTAssertEqual(Array(data.prefix(Int(max(0, count)))), Array("NEW".utf8))
        }
    }

    func testRenameOverRetainsVictimUntilReclaim() throws {
        try runAsync {
            let image = try ImageSession()
            XCTAssertEqual(image.close(), 0)
            let volume = NTFSVolume(resource: ImageBlockIO(image.device), volumeName: FSFileName(string: "TEST"),
                                    volumeID: .init(uuid: UUID()), readOnly: false)
            defer { volume.finishVolume() }
            let root = try volume.activateVolume()
            let sourceName = FSFileName(string: "source")
            let targetName = FSFileName(string: "target")
            let (source, _) = try await volume.createItem(named: sourceName, type: .file, inDirectory: root,
                                                          attributes: FSItem.SetAttributesRequest())
            let (victim, _) = try await volume.createItem(named: targetName, type: .file, inDirectory: root,
                                                          attributes: FSItem.SetAttributesRequest())
            _ = try await volume.write(contents: Data("SOURCE".utf8), to: source, at: 0)
            _ = try await volume.write(contents: Data("VICTIM DATA".utf8), to: victim, at: 0)
            _ = try await volume.renameItem(source, inDirectory: root, named: sourceName, to: targetName,
                                           inDirectory: root, overItem: victim)
            _ = try await volume.write(contents: Data("CHANGED VICTIM".utf8), to: victim, at: 0)
            let attributes = try await volume.attributes(FSItem.GetAttributesRequest(), of: source)
            XCTAssertEqual(attributes.size, 6)
            let victimAttributes = try await volume.attributes(FSItem.GetAttributesRequest(), of: victim)
            XCTAssertEqual(victimAttributes.linkCount, 0)
            let (lookedUp, _) = try await volume.lookupItem(named: targetName, inDirectory: root)
            XCTAssertTrue(lookedUp === source)
            XCTAssertEqual(try volume.visibleEntries(in: root as! NTFSItem).map(\.name), ["target"])
            try await volume.reclaimItem(victim)
            await volume.unmount()
            try image.mount(readOnly: true)
            var data = [UInt8](repeating: 0, count: 32)
            let count = nk_read(image.volume, "/target", 0, 32, &data)
            XCTAssertEqual(Array(data.prefix(Int(max(0, count)))), Array("SOURCE".utf8))
        }
    }

    func testRemovedChildDoesNotPreventRemovingItsParentDirectory() throws {
        try runAsync {
            let session = try VolumeImage()
            let directory = try await session.create("directory", type: .directory)
            let child = try await session.create("child", parent: directory)
            _ = try await session.volume.write(contents: Data("OLD CHILD".utf8), to: child, at: 0)
            try await session.volume.removeItem(child, named: FSFileName(string: "child"), fromDirectory: directory)
            try await session.volume.removeItem(directory, named: FSFileName(string: "directory"), fromDirectory: session.root)
            let replacement = try await session.create("directory", type: .directory)
            let newChild = try await session.create("child", parent: replacement)
            _ = try await session.volume.write(contents: Data("NEW".utf8), to: newChild, at: 0)
            _ = try await session.volume.write(contents: Data("OLD CHANGED".utf8), to: child, at: 0)
            await self.expectError(ENOENT) { _ = try await session.create("forbidden", parent: directory) }
            XCTAssertEqual(session.volume.finishVolume(), 0)
            XCTAssertEqual(try session.contentsAfterClose("/directory/child"), Data("NEW".utf8))
        }
    }

    func testNonemptyAndTypeMismatchedDirectoryOperationsPreserveNamespace() throws {
        try runAsync {
            let session = try VolumeImage()
            let file = try await session.create("file")
            let directory = try await session.create("directory", type: .directory)
            _ = try await session.create("child", parent: directory)
            let empty = try await session.create("empty", type: .directory)
            await self.expectError(ENOTEMPTY) {
                try await session.volume.removeItem(directory, named: FSFileName(string: "directory"), fromDirectory: session.root)
            }
            await self.expectError(EISDIR) { try await session.rename(file, from: "file", to: "directory", over: directory) }
            await self.expectError(ENOTDIR) { try await session.rename(empty, from: "empty", to: "file", over: file) }
            await self.expectError(ENOTEMPTY) { try await session.rename(empty, from: "empty", to: "directory", over: directory) }
            XCTAssertEqual(Set(try session.volume.visibleEntries(in: session.root as! NTFSItem).map(\.name)),
                           Set(["file", "directory", "empty"]))
            XCTAssertEqual(session.volume.finishVolume(), 0)
        }
    }

    func testStaleNameArgumentsCannotMoveOrRemoveAnotherEntry() throws {
        try runAsync {
            let session = try VolumeImage()
            let source = try await session.create("source")
            let victim = try await session.create("victim")
            try await session.rename(victim, from: "victim", to: "elsewhere")
            await self.expectError(ENOENT) { try await session.rename(source, from: "source", to: "victim", over: victim) }
            await self.expectError(ENOENT) { try await session.rename(source, from: "wrong-name", to: "moved") }
            await self.expectError(ENOENT) {
                try await session.volume.removeItem(source, named: FSFileName(string: "elsewhere"), fromDirectory: session.root)
            }
            XCTAssertEqual(Set(try session.volume.visibleEntries(in: session.root as! NTFSItem).map(\.name)),
                           Set(["source", "elsewhere"]))
        }
    }

    func testMovingDirectoryPreservesCachedChildIdentityAndIO() throws {
        try runAsync {
            let session = try VolumeImage()
            let directory = try await session.create("原目录 😀", type: .directory)
            let child = try await session.create("child", parent: directory)
            let attributes = try await session.volume.attributes(FSItem.GetAttributesRequest(), of: child)
            try await session.rename(directory, from: "原目录 😀", to: "新目录 é")
            let (lookedUp, _) = try await session.volume.lookupItem(named: FSFileName(string: "child"), inDirectory: directory)
            XCTAssertTrue(lookedUp === child)
            let movedAttributes = try await session.volume.attributes(FSItem.GetAttributesRequest(), of: child)
            XCTAssertEqual(attributes.fileID, movedAttributes.fileID)
            _ = try await session.volume.write(contents: Data("MOVED".utf8), to: child, at: 0)
            XCTAssertEqual(session.volume.finishVolume(), 0)
            XCTAssertEqual(try session.contentsAfterClose("/新目录 é/child"), Data("MOVED".utf8))
        }
    }

    func testUnmountCleansPendingStorageAndInvalidatesOldItems() throws {
        try runAsync {
            let session = try VolumeImage()
            let removed = try await session.create("removed")
            try await session.volume.removeItem(removed, named: FSFileName(string: "removed"), fromDirectory: session.root)
            XCTAssertEqual(session.volume.finishVolume(), 0)
            let freshRoot = try session.volume.activateVolume()
            XCTAssertTrue(try session.volume.visibleEntries(in: freshRoot as! NTFSItem).isEmpty)
            await self.expectError(ESTALE) { _ = try await session.volume.attributes(FSItem.GetAttributesRequest(), of: removed) }
            await self.expectError(ESTALE) {
                _ = try await session.volume.lookupItem(named: FSFileName(string: "anything"), inDirectory: session.root)
            }
            XCTAssertEqual(session.volume.finishVolume(), 0)
            try session.image.mount(readOnly: true)
            XCTAssertEqual(nk_is_dirty(session.image.volume), 0)
        }
    }

    func testConcurrentRenameDataAndXattrOperationsKeepUsingSameItem() throws {
        try runAsync {
            let session = try VolumeImage()
            let file = try await session.create("left")
            let attributeName = FSFileName(string: "test.concurrent")
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for index in 0..<200 {
                        try await session.rename(file, from: index % 2 == 0 ? "left" : "right",
                                                  to: index % 2 == 0 ? "right" : "left")
                    }
                }
                group.addTask {
                    for _ in 0..<200 {
                        _ = try await session.volume.write(contents: Data("DATA".utf8), to: file, at: 0)
                        try await session.volume.setXattr(named: attributeName, to: Data("ATTR".utf8), on: file, policy: .alwaysSet)
                        let value = try await session.volume.xattr(named: attributeName, of: file)
                        XCTAssertEqual(value, Data("ATTR".utf8))
                        let attributes = try await session.volume.attributes(FSItem.GetAttributesRequest(), of: file)
                        XCTAssertEqual(attributes.size, 4)
                    }
                }
                try await group.waitForAll()
            }
            XCTAssertEqual(session.volume.finishVolume(), 0)
            XCTAssertEqual(try session.contentsAfterClose("/left"), Data("DATA".utf8))
        }
    }

    func testXattrErrorsPreserveDeviceFailureInsteadOfReportingMissing() throws {
        try runAsync {
            let session = try VolumeImage()
            let file = try await session.create("file")
            let attributeName = FSFileName(string: "test.value")
            await self.expectError(ENOATTR) { _ = try await session.volume.xattr(named: attributeName, of: file) }
            try await session.volume.setXattr(named: attributeName, to: Data("KEEP".utf8), on: file, policy: .mustCreate)
            await self.expectError(EEXIST) {
                try await session.volume.setXattr(named: attributeName, to: Data(), on: file, policy: .mustCreate)
            }
            session.transport.failReads = true
            await self.expectError(EIO) { _ = try await session.volume.xattr(named: attributeName, of: file) }
            await self.expectError(EIO) {
                try await session.volume.setXattr(named: attributeName, to: nil, on: file, policy: .delete)
            }
            session.transport.failReads = false
            XCTAssertEqual(session.volume.finishVolume(), -1)
            try session.image.mount(readOnly: true)
            XCTAssertEqual(nk_is_dirty(session.image.volume), 1)
        }
    }

    func testFailedReclaimOrUnmountCannotClearTheDirtyFlag() throws {
        try runAsync {
            for duringReclaim in [true, false] {
                let session = try VolumeImage()
                let file = try await session.create("removed")
                try await session.volume.removeItem(file, named: FSFileName(string: "removed"), fromDirectory: session.root)
                session.transport.failWrites = true
                if duringReclaim {
                    await self.expectError(EIO) { try await session.volume.reclaimItem(file) }
                }
                XCTAssertEqual(session.volume.finishVolume(), -1)
                session.transport.failWrites = false
                try session.image.mount(readOnly: true)
                XCTAssertEqual(nk_is_dirty(session.image.volume), 1)
            }
        }
    }

    func testFailedRenameRollbackFreezesNamespaceAndRetainsVictimData() throws {
        try runAsync {
            let control = try VolumeImage()
            _ = try await control.create("source")
            let controlVictim = try await control.create("target")
            let before = control.transport.writeCount
            try await control.volume.removeItem(controlVictim, named: FSFileName(string: "target"), fromDirectory: control.root)
            let parkWrites = control.transport.writeCount - before
            XCTAssertGreaterThan(parkWrites, 0)
            XCTAssertEqual(control.volume.finishVolume(), 0)

            let session = try VolumeImage()
            let source = try await session.create("source")
            let victim = try await session.create("target")
            _ = try await session.volume.write(contents: Data("SOURCE".utf8), to: source, at: 0)
            _ = try await session.volume.write(contents: Data("VICTIM".utf8), to: victim, at: 0)
            session.transport.failAfterWrites = session.transport.writeCount + parkWrites
            await self.expectError(EIO) { try await session.rename(source, from: "source", to: "target", over: victim) }
            session.transport.failAfterWrites = nil
            await self.expectError(EIO) { _ = try await session.volume.attributes(FSItem.GetAttributesRequest(), of: source) }
            await self.expectError(EIO) { _ = try await session.volume.lookupItem(named: FSFileName(string: "target"), inDirectory: session.root) }
            XCTAssertEqual(session.volume.finishVolume(), -1)
            XCTAssertEqual(try session.contentsAfterClose((victim as! NTFSItem).path), Data("VICTIM".utf8))
            XCTAssertEqual(nk_is_dirty(session.image.volume), 1)
        }
    }
}
