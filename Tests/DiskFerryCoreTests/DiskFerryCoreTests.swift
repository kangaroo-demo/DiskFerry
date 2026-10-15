import Foundation
import Testing
@testable import DiskFerryCore

private func plist(_ dictionary: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
}

private func info(_ fields: [String: Any] = [:]) throws -> Data {
    try plist(["DeviceIdentifier": "disk8s1", "Internal": false, "WholeDisk": false]
        .merging(fields) { _, new in new })
}

private let expectedID = DeviceIdentifier("disk8s1")!

@Test(arguments: ["disk0", "disk8s1", "disk12s2s1"])
func acceptsSystemDeviceIdentifiers(_ value: String) {
    #expect(DeviceIdentifier(value)?.rawValue == value)
}

@Test(arguments: ["/dev/disk8s1", "../disk8", "-plist", "disk1;touch x", "disk1\n", "disk", "disk1 s2", "disk１", ""])
func rejectsUnsafeDeviceIdentifiers(_ value: String) {
    #expect(DeviceIdentifier(value) == nil)
}

@Test func decodingCannotBypassDeviceValidation() throws {
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(DeviceIdentifier.self, from: Data("\"/dev/disk8\"".utf8))
    }
}

@Test func deduplicatesListingAndRejectsUnexpectedIdentifiers() throws {
    let listing = try plist(["AllDisks": ["disk8", "disk8s1", "disk8s1"]])
    #expect(try DiskutilParser.identifiers(from: listing).map(\.rawValue) == ["disk8", "disk8s1"])
    let unsafe = try plist(["AllDisks": ["disk8", "/dev/disk8s1"]])
    #expect(throws: (any Error).self) { try DiskutilParser.identifiers(from: unsafe) }
}

@Test func genericWindowsPartitionDoesNotImplyNTFS() throws {
    let data = try info(["Content": "Microsoft Basic Data", "VolumeName": "NTFS Backup"])
    let volume = try #require(try DiskutilParser.volume(from: data, expectedID: expectedID))
    #expect(volume.fileSystem == .unknown)
    #expect(!WriteAssessment(volume: volume).isAllowed)
}

@Test func writableHardwareDoesNotImplyWritableMount() throws {
    let data = try info(["FilesystemType": "ntfs", "WritableMedia": true, "WritableVolume": false,
                         "MountPoint": "/Volumes/Test", "VolumeName": "测试 🛶", "VolumeSize": UInt64(5_000_000_000)])
    let volume = try #require(try DiskutilParser.volume(from: data, expectedID: expectedID))
    #expect(volume.fileSystem == .ntfs)
    #expect(volume.access == .readOnly)
    #expect(volume.name == "测试 🛶")
    #expect(volume.totalBytes == 5_000_000_000)
}

@Test func diskFerryExtensionTypeRemainsNTFSWithoutClaimingWriteCapability() throws {
    let data = try info(["FilesystemType": "diskferry_ntfs", "WritableMedia": true,
                         "WritableVolume": false, "MountPoint": "/Volumes/Test"])
    let volume = try #require(try DiskutilParser.volume(from: data, expectedID: expectedID))
    #expect(volume.fileSystem == .ntfs)
    #expect(volume.access == .readOnly)
    #expect(!WriteAssessment(volume: volume).isAllowed)
}

@Test func missingWritableVolumeRemainsUnknown() throws {
    let data = try info(["FilesystemType": "ntfs", "WritableMedia": true, "Writable": true, "MountPoint": "/Volumes/Test"])
    let volume = try #require(try DiskutilParser.volume(from: data, expectedID: expectedID))
    #expect(volume.access == .unknown)
}

@Test func volumeWithoutMountPointIsUnmounted() throws {
    let data = try info(["FilesystemType": "ntfs", "WritableVolume": true])
    #expect(try DiskutilParser.volume(from: data, expectedID: expectedID)?.access == .unmounted)
}

@Test func missingLocationDoesNotBecomeExternal() throws {
    let data = try plist(["DeviceIdentifier": "disk8s1", "FilesystemType": "ntfs"])
    let volume = try #require(try DiskutilParser.volume(from: data, expectedID: expectedID))
    #expect(volume.location == .unknown)
    #expect(WriteAssessment(volume: volume).blockers.contains(.unknownLocation))
}

@Test func detectsIdentityChangeDuringScan() throws {
    let data = try info(["DeviceIdentifier": "disk9s1", "FilesystemType": "ntfs"])
    #expect(throws: DiscoveryError.identityChanged) { try DiskutilParser.volume(from: data, expectedID: expectedID) }
}

@Test func skipsNonVolumeContainersButKeepsWholeDiskFilesystems() throws {
    let empty = try info(["WholeDisk": true, "Content": "GUID_partition_scheme"])
    #expect(try DiskutilParser.volume(from: empty, expectedID: expectedID) == nil)
    let formatted = try info(["WholeDisk": true, "FilesystemType": "ntfs"])
    #expect(try DiskutilParser.volume(from: formatted, expectedID: expectedID)?.fileSystem == .ntfs)
}

@Test func invalidCapacityDoesNotOverflowUsage() throws {
    let data = try info(["FilesystemType": "exfat", "VolumeSize": UInt64(10), "FreeSpace": UInt64(20)])
    #expect(try DiskutilParser.volume(from: data, expectedID: expectedID)?.usedFraction == nil)
}

@Test func sizeFallsBackWhenVolumeSizeIsZero() throws {
    let data = try info(["FilesystemType": "ntfs", "VolumeSize": 0, "TotalSize": UInt64(20), "FreeSpace": UInt64(5)])
    let volume = try #require(try DiskutilParser.volume(from: data, expectedID: expectedID))
    #expect(volume.totalBytes == 20)
    #expect(volume.usedFraction == 0.75)
}

@Test func malformedSystemOutputIsAnError() {
    #expect(throws: (any Error).self) { try DiskutilParser.identifiers(from: Data("not a plist".utf8)) }
}

@Test(arguments: [DiskLocation.external, .internal, .unknown])
func noPreviewVolumeCanBecomeWriteEligible(_ location: DiskLocation) {
    let volume = Volume(id: expectedID, name: "Test", fileSystem: .ntfs, location: location,
                        mountPoint: "/Volumes/Test", access: .readWrite, writableMedia: true)
    let assessment = WriteAssessment(volume: volume)
    #expect(!assessment.isAllowed)
    #expect(assessment.blockers.contains(.engineNotIntegrated))
    #expect(assessment.blockers.contains(.healthNotChecked))
    if location == .internal { #expect(assessment.blockers.contains(.internalDisk)) }
}

@Test func demoReportsStayExplicitlyMarked() throws {
    let report = DiagnosticReport(environment: .inspect(), snapshot: .demo)
    let root = try #require(try JSONSerialization.jsonObject(with: report.json()) as? [String: Any])
    let snapshot = try #require(root["snapshot"] as? [String: Any])
    let environment = try #require(root["environment"] as? [String: Any])
    #expect(snapshot["isDemo"] as? Bool == true)
    #expect(environment["writeEngineIntegrated"] as? Bool == false)
    #expect(root["schemaVersion"] as? Int == 2)
}
