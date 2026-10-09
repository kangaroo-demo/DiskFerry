import Foundation

public enum EjectionError: LocalizedError, Equatable {
    case unsafeIdentity, identityChanged, systemRefused, stillPresent
    public var errorDescription: String? {
        switch self {
        case .unsafeIdentity: "无法确认这是同一块外置磁盘。请刷新后重试。"
        case .identityChanged: "磁盘已断开或发生变化，已取消推出。请刷新后重试。"
        case .systemRefused: "磁盘正在使用中，或系统未能完成推出。请关闭相关文件后重试。"
        case .stillPresent: "系统尚未确认磁盘已推出，请暂时不要拔出磁盘。"
        }
    }
}

public enum EjectionSafety {
    public static func validate(expected: Volume, current: Volume) throws -> DeviceIdentifier {
        guard expected.location == .external, current.location == .external,
              expected.hasSafeIdentity, let root = expected.wholeDiskID else {
            throw EjectionError.unsafeIdentity
        }
        guard expected.id == current.id, expected.preferenceKey == current.preferenceKey,
              root == current.wholeDiskID, expected.mediaUUID == current.mediaUUID,
              expected.fileSystem == current.fileSystem, expected.totalBytes == current.totalBytes,
              expected.mountPoint == current.mountPoint else { throw EjectionError.identityChanged }
        if let liveIdentity = expected.liveIdentity {
            guard liveIdentity.isValid, liveIdentity == current.liveIdentity else { throw EjectionError.identityChanged }
        }
        return root
    }
    static func validateWholeDisk(_ data: Data, expected: DeviceIdentifier) throws {
        struct Identity: Decodable {
            let id: String
            let whole: Bool
            let internalDisk: Bool
            enum CodingKeys: String, CodingKey {
                case id = "DeviceIdentifier", whole = "WholeDisk", internalDisk = "Internal"
            }
        }
        let identity = try PropertyListDecoder().decode(Identity.self, from: data)
        guard identity.id == expected.rawValue, identity.whole, !identity.internalDisk else {
            throw EjectionError.unsafeIdentity
        }
    }
}

/// Only explicit user actions call this actor. Never force unmount a busy device.
public actor DiskEjector {
    private let query: @Sendable (DiskutilQuery) throws -> Data
    private let identity: @Sendable (DeviceIdentifier, DeviceIdentifier?) -> LiveDiskIdentity?
    public init() {
        query = { try $0.execute() }
        identity = { LiveDiskInspector.identity(for: $0, wholeDisk: $1) }
    }
    init(query: @escaping @Sendable (DiskutilQuery) throws -> Data,
         identity: @escaping @Sendable (DeviceIdentifier, DeviceIdentifier?) -> LiveDiskIdentity? = { _, _ in nil }) {
        self.query = query
        self.identity = identity
    }
    public func eject(_ expected: Volume) async throws {
        let data = try query(.info(expected.id))
        guard let parsed = try DiskutilParser.volume(from: data, expectedID: expected.id) else {
            throw EjectionError.identityChanged
        }
        let current = parsed.identified(with: identity(parsed.id, parsed.wholeDiskID))
        let root = try EjectionSafety.validate(expected: expected, current: current)
        try EjectionSafety.validateWholeDisk(query(.info(root)), expected: root)
        try Task.checkCancellation()
        _ = try query(.eject(root))
        for _ in 0..<3 {
            let ids = try DiskutilParser.identifiers(from: query(.list))
            if !ids.contains(root) && !ids.contains(expected.id) { return }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw EjectionError.stillPresent
    }
}
