import DiskArbitration
import IOKit

/// Kernel media-object identities last for this connection, never for saved policy.
public struct LiveDiskIdentity: Codable, Sendable, Equatable {
    public let mediaRegistryID: UInt64
    public let wholeDiskRegistryID: UInt64
    public var isValid: Bool { mediaRegistryID != 0 && wholeDiskRegistryID != 0 }
    public init(mediaRegistryID: UInt64, wholeDiskRegistryID: UInt64) {
        self.mediaRegistryID = mediaRegistryID
        self.wholeDiskRegistryID = wholeDiskRegistryID
    }
}

enum LiveDiskInspector {
    /// Public metadata APIs only; this does not open or read the disk's blocks.
    static func identity(for id: DeviceIdentifier, wholeDisk: DeviceIdentifier?) -> LiveDiskIdentity? {
        guard let wholeDisk, let session = DASessionCreate(nil) else { return nil }
        func registryID(_ device: DeviceIdentifier) -> UInt64? {
            guard let disk = DADiskCreateFromBSDName(nil, session, device.rawValue) else { return nil }
            let media = DADiskCopyIOMedia(disk)
            guard media != IO_OBJECT_NULL else { return nil }
            defer { IOObjectRelease(media) }
            var identity: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(media, &identity) == KERN_SUCCESS, identity != 0 else { return nil }
            return identity
        }
        guard let media = registryID(id), let root = registryID(wholeDisk) else { return nil }
        return LiveDiskIdentity(mediaRegistryID: media, wholeDiskRegistryID: root)
    }
}
