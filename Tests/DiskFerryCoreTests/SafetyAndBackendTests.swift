import Foundation
import Testing
@testable import DiskFerryCore

private func plistData(_ value: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
}

private func diskInfo(uuid: String? = "AABB", location: DiskLocation = .external,
                      parent: String = "disk8", media: String = "MEDIA", size: UInt64 = 65536,
                      mount: String = "/Volumes/Test") throws -> Data {
    var info: [String: Any] = ["DeviceIdentifier": "disk8s1", "WholeDisk": false,
        "FilesystemType": "ntfs", "VolumeName": "Test", "ParentWholeDisk": parent,
        "MediaUUID": media, "VolumeSize": size, "MountPoint": mount, "WritableVolume": false]
    if location != .unknown { info["Internal"] = location == .internal }
    if let uuid { info["VolumeUUID"] = uuid }
    return try plistData(info)
}

private func parsed(_ data: Data) throws -> Volume {
    try #require(try DiskutilParser.volume(from: data, expectedID: DeviceIdentifier("disk8s1")!))
}

@Test func volumePoliciesFollowUUIDAcrossDeviceRenumbering() throws {
    let first = try parsed(diskInfo(uuid: "aabb"))
    let renumbered = Volume(id: DeviceIdentifier("disk12s2")!, name: "Test", fileSystem: .ntfs,
                            location: .external, volumeUUID: "AABB")
    let different = try parsed(diskInfo(uuid: "CCDD"))
    var preferences = UserPreferences()
    preferences.setPolicy(.readOnly, for: first)
    #expect(preferences.policy(for: renumbered) == .readOnly)
    #expect(preferences.policy(for: different) == .automatic)
    preferences.setPolicy(.automatic, for: renumbered)
    #expect(preferences.volumePolicies.isEmpty)
    preferences.setPolicy(.unmanaged, for: try parsed(diskInfo(uuid: nil)))
    #expect(preferences.volumePolicies.isEmpty)
}

@Test @MainActor func preferencesPersistAndDemoCannotOverwriteThem() throws {
    let name = "DiskFerryTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = PreferencesStore(defaults: defaults)
    #expect(!store.load().automaticWriting)
    var value = store.load()
    value.automaticWriting = true
    value.showMenuBarIcon = false
    value.setPolicy(.readOnly, for: try parsed(diskInfo()))
    try store.save(value)
    #expect(PreferencesStore(defaults: defaults).load() == value)
    let demo = PreferencesStore(defaults: nil)
    try demo.save(UserPreferences())
    #expect(store.load() == value)
    defaults.set(Data("invalid".utf8), forKey: "DiskFerry.preferences.v1")
    #expect(store.load() == UserPreferences())
}

@Test(arguments: [DiskLocation.internal, .unknown])
func ejectionRejectsInternalAndUnknownDisks(_ location: DiskLocation) throws {
    let volume = try parsed(diskInfo(location: location))
    #expect(throws: EjectionError.unsafeIdentity) { try EjectionSafety.validate(expected: volume, current: volume) }
}

@Test func ejectionRejectsMissingOrChangedVolumeIdentity() throws {
    let expected = try parsed(diskInfo())
    let unidentified = try parsed(diskInfo(uuid: nil))
    #expect(throws: EjectionError.unsafeIdentity) { try EjectionSafety.validate(expected: unidentified, current: unidentified) }
    for changed in [try diskInfo(uuid: "REPLACEMENT"), try diskInfo(parent: "disk9"),
                    try diskInfo(media: "REPLACEMENT"), try diskInfo(size: 99999),
                    try diskInfo(mount: "/Volumes/Replaced")] {
        let current = try parsed(changed)
        #expect(throws: EjectionError.identityChanged) { try EjectionSafety.validate(expected: expected, current: current) }
    }
}

@Test func NTFSWithoutUUIDCanUseItsCurrentMediaConnection() throws {
    let parsed = try parsed(diskInfo(uuid: nil))
    let identity = LiveDiskIdentity(mediaRegistryID: 123, wholeDiskRegistryID: 120)
    let connected = parsed.identified(with: identity)
    #expect(connected.preferenceKey == nil)
    #expect(try EjectionSafety.validate(expected: connected, current: connected).rawValue == "disk8")
    let replaced = parsed.identified(with: LiveDiskIdentity(mediaRegistryID: 456, wholeDiskRegistryID: 450))
    #expect(throws: EjectionError.identityChanged) { try EjectionSafety.validate(expected: connected, current: replaced) }
    #expect(throws: EjectionError.identityChanged) { try EjectionSafety.validate(expected: connected, current: parsed) }
    var preferences = UserPreferences()
    preferences.setPolicy(.readOnly, for: connected)
    #expect(preferences.volumePolicies.isEmpty)
    let invalid = parsed.identified(with: LiveDiskIdentity(mediaRegistryID: 0, wholeDiskRegistryID: 0))
    #expect(!invalid.hasSafeIdentity)
}

@Test func wholeDiskIdentityMustBeConfirmedExternal() throws {
    let root = DeviceIdentifier("disk8")!
    for fields: [String: Any] in [
        ["DeviceIdentifier": "disk8", "WholeDisk": true, "Internal": true],
        ["DeviceIdentifier": "disk9", "WholeDisk": true, "Internal": false],
        ["DeviceIdentifier": "disk8", "WholeDisk": false, "Internal": false]
    ] {
        let data = try plistData(fields)
        #expect(throws: EjectionError.unsafeIdentity) { try EjectionSafety.validateWholeDisk(data, expected: root) }
    }
}

@Test func reusedDeviceNumberNeverReachesEject() async throws {
    let expected = try parsed(diskInfo())
    let replacement = try diskInfo(uuid: "REPLACEMENT")
    let ejector = DiskEjector { query in
        switch query {
        case .info: return replacement
        default: Issue.record("Identity mismatch must stop before eject or list"); return Data()
        }
    }
    await #expect(throws: EjectionError.identityChanged) { try await ejector.eject(expected) }
}

@Test func busyDiskRefusalDoesNotForceOrClaimSuccess() async throws {
    let partition = try diskInfo()
    let expected = try parsed(partition)
    let root = try plistData(["DeviceIdentifier": "disk8", "WholeDisk": true, "Internal": false])
    let ejector = DiskEjector { query in
        switch query {
        case .info(let id): return id.rawValue == "disk8" ? root : partition
        case .eject:
            #expect(query.arguments == ["eject", "disk8"])
            throw EjectionError.systemRefused
        case .list: Issue.record("System refusal must end the operation"); return Data()
        }
    }
    await #expect(throws: EjectionError.systemRefused) { try await ejector.eject(expected) }
}

@Test func successfulEjectRequiresSystemAbsence() async throws {
    let partition = try diskInfo()
    let expected = try parsed(partition)
    let root = try plistData(["DeviceIdentifier": "disk8", "WholeDisk": true, "Internal": false])
    let gone = try plistData(["AllDisks": [String]()])
    let stillPresent = try plistData(["AllDisks": ["disk8", "disk8s1"]])
    func fake(_ listing: Data) -> DiskEjector {
        DiskEjector { query in
            switch query {
            case .info(let id): return id.rawValue == "disk8" ? root : partition
            case .eject: return Data("Disk ejected".utf8)
            case .list: return listing
            }
        }
    }
    try await fake(gone).eject(expected)
    await #expect(throws: EjectionError.stillPresent) { try await fake(stillPresent).eject(expected) }
}

private func bootSector() -> Data {
    var data = Data(count: 512)
    data.replaceSubrange(3..<11, with: "NTFS    ".utf8)
    data[12] = 2 // 512-byte sectors, little endian
    data[13] = 8
    data[41] = 0x10 // 4096 sectors
    data[48] = 4
    data[56] = 8
    data[64] = 246 // -10 => 1024 bytes per MFT record
    data[510] = 0x55
    data[511] = 0xAA
    return data
}

@Test func bootProbeRecognizesOnlyBoundedNTFSGeometry() throws {
    let probe = try NTFSBootSector(data: bootSector(), resourceBytes: 2_097_152)
    #expect(probe.bytesPerSector == 512)
    #expect(probe.fileRecordBytes == 1024)
    #expect(throws: NTFSProbeError.truncated) { try NTFSBootSector(data: Data(count: 511)) }
    #expect(throws: NTFSProbeError.truncated) { try NTFSBootSector(data: bootSector(), resourceBytes: 1024) }
    var invalid = bootSector()
    invalid[3] = 0
    #expect(throws: NTFSProbeError.notNTFS) { try NTFSBootSector(data: invalid) }
    invalid = bootSector()
    invalid[13] = 3
    #expect(throws: NTFSProbeError.invalidGeometry) { try NTFSBootSector(data: invalid) }
    invalid = bootSector()
    for index in 40..<48 { invalid[index] = 255 }
    #expect(throws: NTFSProbeError.invalidGeometry) { try NTFSBootSector(data: invalid) }
    invalid = bootSector()
    invalid[64] = 128 // Int8.min must never overflow the shift
    #expect(throws: NTFSProbeError.unsupportedRecordSize) { try NTFSBootSector(data: invalid) }
    invalid[64] = 0
    #expect(throws: NTFSProbeError.unsupportedRecordSize) { try NTFSBootSector(data: invalid) }
}

@Test func imageProbeRejectsDevicesAndDirectories() {
    #expect(throws: NTFSProbeError.notRegularFile) { try NTFSBootSector.inspectImage(at: URL(fileURLWithPath: "/dev/null")) }
    #expect(throws: NTFSProbeError.notRegularFile) { try NTFSBootSector.inspectImage(at: URL(fileURLWithPath: NSTemporaryDirectory())) }
}
