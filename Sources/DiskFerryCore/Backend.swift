import Foundation
import FSKit
import Darwin

public enum DiskFerryVersion {
    public static let current = "0.2.0-dev"
}

public struct FileSystemModule: Codable, Sendable, Equatable {
    public let bundleIdentifier: String
    public let enabled: Bool
}

public struct BackendReport: Codable, Sendable {
    public let fsKitAvailable: Bool
    public let modules: [FileSystemModule]
    public let inspectionError: String?
    /// An installed extension alone is never evidence of a qualified write backend.
    public let writeEngineQualified: Bool
    public static let pending = BackendReport(fsKitAvailable: false, modules: [],
                                              inspectionError: nil, writeEngineQualified: false)
}

private final class InspectionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BackendReport, Never>?
    init(_ continuation: CheckedContinuation<BackendReport, Never>) { self.continuation = continuation }
    func resolve(_ report: BackendReport) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: report)
    }
}

public enum BackendInspector {
    public static func inspect() async -> BackendReport {
        guard #available(macOS 15.4, *) else { return .pending }
        return await withCheckedContinuation { continuation in
            let completion = InspectionCompletion(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) {
                completion.resolve(BackendReport(fsKitAvailable: true, modules: [],
                    inspectionError: "FSKit 扩展查询超时。", writeEngineQualified: false))
            }
            FSClient.shared.fetchInstalledExtensions { modules, error in
                completion.resolve(BackendReport(fsKitAvailable: true,
                    modules: (modules ?? []).map {
                        FileSystemModule(bundleIdentifier: $0.bundleIdentifier, enabled: $0.isEnabled)
                    }.sorted { $0.bundleIdentifier < $1.bundleIdentifier },
                    inspectionError: error?.localizedDescription, writeEngineQualified: false))
            }
        }
    }
}

public enum NTFSProbeError: LocalizedError, Equatable {
    case truncated, notNTFS, invalidGeometry, unsupportedRecordSize, notRegularFile
    public var errorDescription: String? {
        switch self {
        case .truncated: "镜像或引导扇区不完整。"
        case .notNTFS: "未识别到 NTFS 引导扇区。"
        case .invalidGeometry: "NTFS 的扇区、簇或元数据位置无效。"
        case .unsupportedRecordSize: "不支持此 NTFS 记录大小。"
        case .notRegularFile: "只允许检测普通镜像文件，不直接访问块设备。"
        }
    }
}

/// Recognition only: this header cannot establish volume health or write safety.
public struct NTFSBootSector: Codable, Sendable, Equatable {
    public let bytesPerSector: UInt64
    public let sectorsPerCluster: UInt64
    public let totalSectors: UInt64
    public let mftCluster: UInt64
    public let mftMirrorCluster: UInt64
    public let fileRecordBytes: UInt64
    public let volumeSerial: UInt64

    public init(data: Data, resourceBytes: UInt64? = nil) throws {
        guard data.count >= 512 else { throw NTFSProbeError.truncated }
        let bytes = Array(data.prefix(512))
        guard bytes[3..<11].elementsEqual(Array("NTFS    ".utf8)),
              bytes[510] == 0x55, bytes[511] == 0xAA else { throw NTFSProbeError.notNTFS }
        func little(_ offset: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(0) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
        }
        let sector = little(11, 2)
        let cluster = UInt64(bytes[13])
        let sectors = little(40, 8)
        let mft = little(48, 8)
        let mirror = little(56, 8)
        guard [512, 1024, 2048, 4096].contains(sector),
              cluster > 0, cluster <= 128, cluster.nonzeroBitCount == 1,
              sectors > 0, sectors <= UInt64.max / sector,
              mft > 0, mft < sectors / cluster, mirror > 0, mirror < sectors / cluster else {
            throw NTFSProbeError.invalidGeometry
        }
        if let resourceBytes, sectors * sector > resourceBytes { throw NTFSProbeError.truncated }
        let encoded = Int(Int8(bitPattern: bytes[64]))
        let record: UInt64
        if encoded < 0 {
            guard encoded >= -20 else { throw NTFSProbeError.unsupportedRecordSize }
            record = UInt64(1) << (-encoded)
        } else {
            guard encoded > 0 else { throw NTFSProbeError.unsupportedRecordSize }
            record = UInt64(encoded) * sector * cluster
        }
        guard record >= 512, record <= 1_048_576, record.nonzeroBitCount == 1 else {
            throw NTFSProbeError.unsupportedRecordSize
        }
        bytesPerSector = sector
        sectorsPerCluster = cluster
        totalSectors = sectors
        mftCluster = mft
        mftMirrorCluster = mirror
        fileRecordBytes = record
        volumeSerial = little(72, 8)
    }

    public static func inspectImage(at url: URL) throws -> NTFSBootSector {
        let resolved = url.resolvingSymlinksInPath()
        let descriptor = open(resolved.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var properties = stat()
        guard fstat(descriptor, &properties) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Verify the opened descriptor, so a replaced path cannot bypass the regular-file gate.
        guard properties.st_mode & S_IFMT == S_IFREG, properties.st_size >= 0 else {
            throw NTFSProbeError.notRegularFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try handle.read(upToCount: 512) else { throw NTFSProbeError.truncated }
        return try NTFSBootSector(data: data, resourceBytes: UInt64(properties.st_size))
    }
}

/// Adapter compiled against the public FSKit block-resource API. It performs
/// only a read and rejects proxy/revoked resources; no raw device path is opened.
@available(macOS 15.4, *)
public enum FSKitNTFSProbe {
    public static func inspect(_ resource: FSBlockDeviceResource) throws -> NTFSBootSector {
        guard !resource.isRevoked, resource.blockSize > 0,
              resource.blockCount <= UInt64.max / resource.blockSize,
              resource.physicalBlockSize >= 512, resource.physicalBlockSize <= 65536 else {
            throw NTFSProbeError.invalidGeometry
        }
        var data = Data(count: Int(resource.physicalBlockSize))
        let count = try data.withUnsafeMutableBytes { buffer in
            try resource.read(into: buffer, startingAt: 0, length: buffer.count)
        }
        guard count == data.count else { throw NTFSProbeError.truncated }
        return try NTFSBootSector(data: data, resourceBytes: resource.blockSize * resource.blockCount)
    }
}
