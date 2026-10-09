import Foundation
import Darwin

public struct ScanIssue: Sendable, Codable, Identifiable {
    public let device: String
    public let message: String
    public var id: String { device }
}

public struct DiskSnapshot: Sendable, Codable {
    public let scannedAt: Date
    public let isDemo: Bool
    public let volumes: [Volume]
    public let issues: [ScanIssue]
    public var ntfsVolumes: [Volume] { volumes.filter { $0.fileSystem == .ntfs } }

    public static var demo: DiskSnapshot {
        DiskSnapshot(scannedAt: Date(), isDemo: true, volumes: [
            Volume(id: DeviceIdentifier("disk90s1")!, name: "旅行档案", fileSystem: .ntfs, location: .external,
                   totalBytes: 1_000_000_000_000, freeBytes: 640_000_000_000,
                   mountPoint: "/Volumes/DiskFerry-Demo-Archive", access: .readOnly, writableMedia: true, busProtocol: "USB",
                   volumeUUID: "DISKFERRY-DEMO-ARCHIVE", wholeDiskID: DeviceIdentifier("disk90")),
            Volume(id: DeviceIdentifier("disk91s1")!, name: "工作随行", fileSystem: .exfat, location: .external,
                   totalBytes: 256_000_000_000, freeBytes: 185_000_000_000,
                   mountPoint: "/Volumes/DiskFerry-Demo-Work", access: .readWrite, writableMedia: true, busProtocol: "USB"),
        ], issues: [])
    }
}

public actor DiskScanner {
    public init() {}

    public func scan() throws -> DiskSnapshot {
        let data = try DiskutilQuery.list.execute()
        let identifiers = try DiskutilParser.identifiers(from: data)
        var volumes: [Volume] = []
        var issues: [ScanIssue] = []
        for id in identifiers {
            try Task.checkCancellation()
            do {
                let info = try DiskutilQuery.info(id).execute()
                if let volume = try DiskutilParser.volume(from: info, expectedID: id), volume.location != .internal {
                    volumes.append(volume.identified(with: LiveDiskInspector.identity(for: id, wholeDisk: volume.wholeDiskID)))
                }
            } catch {
                issues.append(ScanIssue(device: id.rawValue, message: error.localizedDescription))
            }
        }
        return DiskSnapshot(scannedAt: Date(), isDemo: false,
                            volumes: volumes.sorted { $0.id.rawValue.localizedStandardCompare($1.id.rawValue) == .orderedAscending }, issues: issues)
    }
}

/// Closed system queries and a non-forced eject, gated by DiskEjector identity checks.
enum DiskutilQuery: Sendable {
    case list, info(DeviceIdentifier), eject(DeviceIdentifier)

    var arguments: [String] {
        switch self {
        case .list: ["list", "-plist", "external"]
        case .info(let id): ["info", "-plist", id.rawValue]
        case .eject(let id): ["eject", id.rawValue]
        }
    }

    func execute() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // The parent must release its writer; otherwise EOF never arrives after the child exits.
        try pipe.fileHandleForWriting.close()
        // Drain the pipe while the subprocess runs, including stderr, to avoid pipe-buffer deadlocks.
        // The watchdog only signals this child; it never touches the disk being queried.
        let terminateTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let timeout: Double = if case .eject = self { 30 } else { 8 }
        terminateTimer.schedule(deadline: .now() + timeout)
        terminateTimer.setEventHandler { if process.isRunning { process.terminate() } }
        let killTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        killTimer.schedule(deadline: .now() + timeout + 1)
        killTimer.setEventHandler { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        terminateTimer.resume()
        killTimer.resume()
        defer {
            terminateTimer.cancel()
            killTimer.cancel()
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            if case .eject = self { throw EjectionError.systemRefused }
            throw DiscoveryError.commandFailed(process.terminationStatus)
        }
        guard !data.isEmpty else { throw DiscoveryError.invalidCommandOutput }
        return data
    }
}
