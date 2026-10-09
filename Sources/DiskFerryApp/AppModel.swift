import AppKit
import DiskFerryCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    let isDemo: Bool
    let loginItem: LoginItemController
    @Published var snapshot: DiskSnapshot?
    @Published var environment = EnvironmentReport.inspect()
    @Published var backend = BackendReport.pending
    @Published var backendInspected = false
    @Published var isScanning = false
    @Published var selectedPage = SettingsPage.general
    @Published var selectedVolumeID: DeviceIdentifier?
    @Published var ejectingDevice: DeviceIdentifier?
    @Published var errorMessage: String?
    @Published var scanError: String?
    @Published var notice: String?
    @Published var preferences: UserPreferences {
        didSet {
            do { try store.save(preferences) }
            catch { errorMessage = "设置保存失败：\(error.localizedDescription)" }
        }
    }
    private let scanner = DiskScanner()
    private let ejector = DiskEjector()
    private let store: PreferencesStore
    var volumes: [Volume] { snapshot?.ntfsVolumes ?? [] }
    var selectedVolume: Volume? {
        volumes.first { $0.id == selectedVolumeID } ?? volumes.first
    }

    init(isDemo: Bool) {
        self.isDemo = isDemo
        loginItem = LoginItemController(isDemo: isDemo)
        store = PreferencesStore(defaults: isDemo ? nil : .standard)
        preferences = store.load()
    }

    func start() async {
        async let report = BackendInspector.inspect()
        await refresh()
        backend = await report
        backendInspected = true
    }

    func refresh() async {
        loginItem.refresh()
        guard !isScanning, ejectingDevice == nil else { return }
        isScanning = true
        defer { isScanning = false }
        environment = .inspect()
        do {
            snapshot = isDemo ? .demo : try await scanner.scan()
            scanError = nil
            if !volumes.contains(where: { $0.id == selectedVolumeID }) {
                selectedVolumeID = volumes.first?.id
            }
        } catch {
            snapshot = nil
            scanError = error.localizedDescription
        }
    }

    func refreshDiagnostics() async {
        async let report = BackendInspector.inspect()
        await refresh()
        backend = await report
        backendInspected = true
    }

    func setPolicy(_ policy: VolumePolicy, for volume: Volume) {
        guard !isDemo else { return }
        preferences.setPolicy(policy, for: volume)
    }

    func openVolume(_ expected: Volume) async -> Bool {
        guard !isDemo, ejectingDevice == nil else { return false }
        do {
            let fresh = try await scanner.scan()
            snapshot = fresh
            guard let volume = fresh.volumes.first(where: { $0.id == expected.id }) else {
                throw EjectionError.identityChanged
            }
            _ = try EjectionSafety.validate(expected: expected, current: volume)
            guard let mountPoint = volume.mountPoint,
                  FileManager.default.fileExists(atPath: mountPoint),
                  NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint, isDirectory: true)) else {
                throw EjectionError.identityChanged
            }
            return true
        } catch {
            errorMessage = "无法打开此磁盘：\(error.localizedDescription)"
            return false
        }
    }

    func eject(_ volume: Volume) async -> Bool {
        guard !isDemo, ejectingDevice == nil else { return false }
        ejectingDevice = volume.id
        errorMessage = nil
        var succeeded = false
        do {
            try await ejector.eject(volume)
            succeeded = true
        } catch { errorMessage = error.localizedDescription }
        ejectingDevice = nil
        await refresh()
        return succeeded
    }

    func exportReport() {
        guard let snapshot else { return }
        let panel = NSSavePanel()
        panel.title = "导出诊断报告"
        panel.nameFieldStringValue = isDemo ? "DiskFerry-demo.json" : "DiskFerry-diagnostics.json"
        panel.allowedContentTypes = [.json]
        panel.message = "包含卷名称、标识、挂载路径及系统环境，不包含磁盘中的文件内容。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DiagnosticReport(environment: environment, snapshot: snapshot,
                                 backend: backend, preferences: preferences).json().write(to: url, options: .atomic)
            notice = "诊断报告已导出。"
        } catch { errorMessage = "导出失败：\(error.localizedDescription)" }
    }
}
