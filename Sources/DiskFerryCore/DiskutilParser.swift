import Foundation

public enum DiskutilParser {
    public static func identifiers(from data: Data) throws -> [DeviceIdentifier] {
        let listing = try PropertyListDecoder().decode(Listing.self, from: data)
        var seen = Set<DeviceIdentifier>()
        return try listing.allDisks.compactMap { value in
            guard let id = DeviceIdentifier(value) else { throw DiscoveryError.invalidIdentifier(value) }
            return seen.insert(id).inserted ? id : nil
        }
    }

    public static func volume(from data: Data, expectedID: DeviceIdentifier) throws -> Volume? {
        let info = try PropertyListDecoder().decode(Info.self, from: data)
        guard info.deviceIdentifier == expectedID.rawValue else { throw DiscoveryError.identityChanged }
        // Partition type Microsoft Basic Data is NOT enough to distinguish NTFS from exFAT.
        // Show unrecognized partitions as unknown, but omit unformatted whole disks and EFI/APFS stores.
        if info.fileSystemType == nil || info.fileSystemType == "" {
            if info.wholeDisk == true || ["EFI", "Apple_APFS", "Apple_partition_map"].contains(info.content ?? "") {
                return nil
            }
        }
        let location: DiskLocation = info.internalDisk.map { $0 ? .internal : .external } ?? .unknown
        let mountPoint = info.mountPoint.flatMap { $0.hasPrefix("/") ? $0 : nil }
        let access: MountAccess = mountPoint == nil ? .unmounted : info.writableVolume.map { $0 ? .readWrite : .readOnly } ?? .unknown
        let size = [info.volumeSize, info.totalSize, info.size].compactMap { $0 }.first { $0 > 0 }
        let name = [info.volumeName, info.mediaName].compactMap { $0 }.first { !$0.isEmpty } ?? expectedID.rawValue
        return Volume(id: expectedID, name: name, fileSystem: FileSystem(type: info.fileSystemType),
                      location: location, totalBytes: size, freeBytes: info.freeSpace,
                      mountPoint: mountPoint, access: access, writableMedia: info.writableMedia,
                      busProtocol: info.busProtocol,
                      volumeUUID: info.volumeUUID, mediaUUID: info.mediaUUID,
                      wholeDiskID: info.parentWholeDisk.flatMap(DeviceIdentifier.init)
                        ?? (info.wholeDisk == true ? expectedID : nil))
    }

    private struct Listing: Decodable {
        let allDisks: [String]
        enum CodingKeys: String, CodingKey { case allDisks = "AllDisks" }
    }

    private struct Info: Decodable {
        let deviceIdentifier: String
        let fileSystemType: String?
        let content: String?
        let wholeDisk: Bool?
        let internalDisk: Bool?
        let volumeName: String?
        let mediaName: String?
        let volumeSize: UInt64?
        let totalSize: UInt64?
        let size: UInt64?
        let freeSpace: UInt64?
        let mountPoint: String?
        let writableVolume: Bool?
        let writableMedia: Bool?
        let busProtocol: String?
        let volumeUUID: String?
        let mediaUUID: String?
        let parentWholeDisk: String?

        enum CodingKeys: String, CodingKey {
            case deviceIdentifier = "DeviceIdentifier", fileSystemType = "FilesystemType", content = "Content"
            case wholeDisk = "WholeDisk", internalDisk = "Internal", volumeName = "VolumeName", mediaName = "MediaName"
            case volumeSize = "VolumeSize", totalSize = "TotalSize", size = "Size", freeSpace = "FreeSpace"
            case mountPoint = "MountPoint", writableVolume = "WritableVolume", writableMedia = "WritableMedia", busProtocol = "BusProtocol"
            case volumeUUID = "VolumeUUID", mediaUUID = "MediaUUID", parentWholeDisk = "ParentWholeDisk"
        }
    }
}

public enum DiscoveryError: LocalizedError, Equatable {
    case invalidIdentifier(String), identityChanged, commandFailed(Int32), invalidCommandOutput

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "磁盘标识符格式异常，已停止处理。"
        case .identityChanged: "扫描时磁盘身份发生变化，请刷新后重试。"
        case .commandFailed(let code): "系统磁盘查询失败（状态 \(code)），设备可能已断开或查询超时。"
        case .invalidCommandOutput: "无法解析系统返回的磁盘信息。"
        }
    }
}
