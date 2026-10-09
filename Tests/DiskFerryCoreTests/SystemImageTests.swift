import Foundation
import Testing
@testable import DiskFerryCore

private func systemQuery(_ executable: String, _ arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    try process.run()
    try pipe.fileHandleForWriting.close()
    let watchdog = DispatchSource.makeTimerSource(queue: .global())
    watchdog.schedule(deadline: .now() + 30)
    watchdog.setEventHandler { if process.isRunning { process.terminate() } }
    watchdog.resume()
    defer { watchdog.cancel(); try? pipe.fileHandleForReading.close() }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "DiskFerryImageTest", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: String(decoding: output, as: UTF8.self)])
    }
    return output
}

/// Opt-in integration test. It copies an ordinary fixture and owns only that copy's attachment.
@Test(.enabled(if: ProcessInfo.processInfo.environment["DISKFERRY_TEST_IMAGE_PATH"] != nil))
func readonlyImageUsesRealSystemIdentityAndNonforcedEject() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["DISKFERRY_TEST_IMAGE_PATH"])
    let fixture = URL(fileURLWithPath: path)
    _ = try NTFSBootSector.inspectImage(at: fixture)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiskFerryImageTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let image = directory.appendingPathComponent("disposable.ntfs")
    try FileManager.default.copyItem(at: fixture, to: image)
    var completed = false
    // A failed test leaves its disposable file for diagnosis if normal detach cannot finish.
    defer {
        if !completed {
            if let owned = try? ownedDevices(image) {
                for id in owned { _ = try? systemQuery("/usr/bin/hdiutil", ["detach", id]) }
            }
        }
        if completed { try? FileManager.default.removeItem(at: directory) }
    }
    let attached = try systemQuery("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-plist",
                                                        "-imagekey", "diskimage-class=CRawDiskImage", image.path])
    let data = try #require(try PropertyListSerialization.propertyList(from: attached, format: nil) as? [String: Any])
    let entities = try #require(data["system-entities"] as? [[String: Any]])
    let entry = try #require(entities.first(where: { $0["mount-point"] != nil }))
    let device = try #require(entry["dev-entry"] as? String)
    let id = try #require(DeviceIdentifier(String(device.dropFirst("/dev/".count))))
    let ownership = try ownedDevices(image)
    try #require(ownership.contains(device))
    let snapshot = try await DiskScanner().scan()
    let volume = try #require(snapshot.volumes.first { $0.id == id })
    try #require(volume.fileSystem == .ntfs)
    try #require(volume.location == .external)
    try #require(volume.access == .readOnly)
    try #require(volume.busProtocol == "Disk Image")
    #expect(volume.hasSafeIdentity)
    let liveIdentity = try #require(volume.liveIdentity)
    #expect(liveIdentity.isValid)
    let secondScan = try await DiskScanner().scan()
    let rechecked = try #require(secondScan.volumes.first { $0.id == id })
    #expect(rechecked.liveIdentity == liveIdentity)
    #expect(try EjectionSafety.validate(expected: volume, current: rechecked) == volume.wholeDiskID)
    try await DiskEjector().eject(volume)
    #expect(try ownedDevices(image).isEmpty)
    let after = try await DiskScanner().scan()
    #expect(!after.volumes.contains { $0.id == id })
    completed = true
}

private func ownedDevices(_ image: URL) throws -> [String] {
    let data = try systemQuery("/usr/bin/hdiutil", ["info", "-plist"])
    let root = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let images = root["images"] as? [[String: Any]] ?? []
    return images.filter { ($0["image-path"] as? String) == image.path }
        .flatMap { $0["system-entities"] as? [[String: Any]] ?? [] }
        .compactMap { $0["dev-entry"] as? String }
}
