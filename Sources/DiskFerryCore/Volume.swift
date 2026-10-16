import Foundation

public struct DeviceIdentifier: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }

    public init?(_ rawValue: String) {
        guard let match = rawValue.range(of: #"^disk[0-9]+(?:s[0-9]+)*$"#, options: .regularExpression),
              match == rawValue.startIndex..<rawValue.endIndex else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let identifier = DeviceIdentifier(value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid disk identifier")
        }
        self = identifier
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum FileSystem: String, Sendable, Codable {
    case ntfs = "NTFS"
    case exfat = "exFAT"
    case apfs = "APFS"
    case fat = "FAT"
    case hfs = "HFS+"
    case other = "其他格式"
    case unknown = "未识别"

    public init(type: String?) {
        switch type?.lowercased() {
        case "ntfs", "windows_ntfs", "diskferry_ntfs": self = .ntfs
        case "exfat": self = .exfat
        case "apfs": self = .apfs
        case "msdos", "fat", "fat16", "fat32": self = .fat
        case "hfs", "hfs+", "hfsx": self = .hfs
        case nil, "": self = .unknown
        default: self = .other
        }
    }
}

public enum DiskLocation: String, Sendable, Codable {
    case external, `internal`, unknown
}

public enum MountAccess: String, Sendable, Codable {
    case readOnly, readWrite, unmounted, unknown

    public var label: String {
        switch self {
        case .readOnly: "系统只读"
        case .readWrite: "系统可写"
        case .unmounted: "未挂载"
        case .unknown: "访问状态未知"
        }
    }
}

public struct Volume: Identifiable, Sendable, Codable, Equatable {
    public let id: DeviceIdentifier
    public let name: String
    public let fileSystem: FileSystem
    public let location: DiskLocation
    public let totalBytes: UInt64?
    public let freeBytes: UInt64?
    public let mountPoint: String?
    public let access: MountAccess
    public let writableMedia: Bool?
    public let busProtocol: String?
    public let volumeUUID: String?
    public let mediaUUID: String?
    public let wholeDiskID: DeviceIdentifier?
    public let liveIdentity: LiveDiskIdentity?

    public init(id: DeviceIdentifier, name: String, fileSystem: FileSystem, location: DiskLocation,
                totalBytes: UInt64? = nil, freeBytes: UInt64? = nil, mountPoint: String? = nil,
                access: MountAccess = .unknown, writableMedia: Bool? = nil, busProtocol: String? = nil,
                volumeUUID: String? = nil, mediaUUID: String? = nil, wholeDiskID: DeviceIdentifier? = nil,
                liveIdentity: LiveDiskIdentity? = nil) {
        self.id = id
        self.name = name
        self.fileSystem = fileSystem
        self.location = location
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.mountPoint = mountPoint
        self.access = access
        self.writableMedia = writableMedia
        self.busProtocol = busProtocol
        self.volumeUUID = volumeUUID
        self.mediaUUID = mediaUUID
        self.wholeDiskID = wholeDiskID
        self.liveIdentity = liveIdentity
    }

    public var hasSafeIdentity: Bool { liveIdentity?.isValid == true || preferenceKey != nil }

    func identified(with identity: LiveDiskIdentity?) -> Volume {
        Volume(id: id, name: name, fileSystem: fileSystem, location: location,
               totalBytes: totalBytes, freeBytes: freeBytes, mountPoint: mountPoint, access: access,
               writableMedia: writableMedia, busProtocol: busProtocol, volumeUUID: volumeUUID,
               mediaUUID: mediaUUID, wholeDiskID: wholeDiskID, liveIdentity: identity)
    }

    /// Device numbers are reused. Persist policies only against a stable volume identity.
    public var preferenceKey: String? {
        guard let uuid = volumeUUID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !uuid.isEmpty, uuid.count <= 128 else { return nil }
        return "volume:\(uuid.uppercased())"
    }

    public var statusLabel: String {
        switch access {
        case .readOnly: "只读"
        case .readWrite: "可读写"
        case .unmounted: "未挂载"
        case .unknown: "状态未知"
        }
    }

    public var usedFraction: Double? {
        guard let totalBytes, totalBytes > 0, let freeBytes, freeBytes <= totalBytes else { return nil }
        return Double(totalBytes - freeBytes) / Double(totalBytes)
    }

    public var writeStatusExplanation: String {
        if fileSystem != .ntfs { return "当前为 \(fileSystem.rawValue) 卷，访问能力由系统提供。" }
        if access == .readWrite { return "系统报告此卷可写。DiskFerry 尚未接入写入引擎，这并不表示由 DiskFerry 提供写入。" }
        return "已识别 NTFS。此预览版只检测磁盘；写入引擎尚未接入。"
    }
}

public enum WriteBlocker: String, Codable, Sendable {
    case notNTFS, internalDisk, unknownLocation, mediaReadOnly, mediaWritabilityUnknown
    case engineNotIntegrated, healthNotChecked
}

/// Deliberately closed in the discovery preview. No code in this package mounts or writes devices.
public struct WriteAssessment: Sendable, Codable {
    public let blockers: [WriteBlocker]
    public var isAllowed: Bool { blockers.isEmpty }

    public init(volume: Volume) {
        var reasons: [WriteBlocker] = [.engineNotIntegrated, .healthNotChecked]
        if volume.fileSystem != .ntfs { reasons.append(.notNTFS) }
        if volume.location == .internal { reasons.append(.internalDisk) }
        if volume.location == .unknown { reasons.append(.unknownLocation) }
        if volume.writableMedia == false { reasons.append(.mediaReadOnly) }
        if volume.writableMedia == nil { reasons.append(.mediaWritabilityUnknown) }
        blockers = reasons
    }
}
