import Foundation

public struct EnvironmentReport: Codable, Sendable {
    public let osVersion: String
    public let processArchitecture: String
    public let hardwareArchitecture: String
    public let fsKitBackendOSRequirementMet: Bool
    public let ntfs3gFilesFound: [String]
    public let macFUSEBundleFound: Bool
    public let writeEngineIntegrated: Bool

    public static func inspect() -> EnvironmentReport {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        var supportsARM64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let hardwareIsARM = sysctlbyname("hw.optional.arm64", &supportsARM64, &size, nil, 0) == 0 && supportsARM64 == 1
        let paths = ["/opt/homebrew/bin/ntfs-3g", "/opt/homebrew/sbin/ntfs-3g",
                     "/usr/local/bin/ntfs-3g", "/usr/local/sbin/ntfs-3g"]
        return EnvironmentReport(osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                                 processArchitecture: arch, hardwareArchitecture: hardwareIsARM ? "arm64" : arch,
                                 fsKitBackendOSRequirementMet: version.majorVersion > 15 || (version.majorVersion == 15 && version.minorVersion >= 4),
                                 ntfs3gFilesFound: paths.filter { FileManager.default.isExecutableFile(atPath: $0) },
                                 macFUSEBundleFound: FileManager.default.fileExists(atPath: "/Library/Filesystems/macfuse.fs"),
                                 writeEngineIntegrated: false)
    }
}

public struct DiagnosticReport: Encodable, Sendable {
    public let schemaVersion = 2
    public let appVersion = DiskFerryVersion.current
    public let environment: EnvironmentReport
    public let snapshot: DiskSnapshot
    public let backend: BackendReport?
    public let preferences: UserPreferences?

    public init(environment: EnvironmentReport, snapshot: DiskSnapshot,
                backend: BackendReport? = nil, preferences: UserPreferences? = nil) {
        self.environment = environment
        self.snapshot = snapshot
        self.backend = backend
        self.preferences = preferences
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
