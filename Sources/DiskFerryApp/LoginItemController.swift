import Combine
import Foundation
import ServiceManagement

@MainActor
protocol LoginItemService: AnyObject {
    var isAvailable: Bool { get }
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
    func openSystemSettings()
}

/// Use macOS's login-item registry as the source of truth, including changes in System Settings.
@MainActor
final class SystemLoginItemService: LoginItemService {
    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() async throws { try await SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status = SMAppService.Status.notRegistered
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?
    let isDemo: Bool
    private let service: any LoginItemService

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }
    var canChange: Bool { !isDemo && service.isAvailable && !isUpdating }
    var help: String {
        if isDemo { return "演示模式不会更改系统登录项。" }
        if !service.isAvailable { return "请打开盘渡应用后设置自启动。" }
        if requiresApproval { return "macOS 尚未允许自启动，请在系统的登录项设置中开启。" }
        return "登录 Mac 后自动启动，只显示菜单栏图标。"
    }

    init(isDemo: Bool, service: any LoginItemService = SystemLoginItemService()) {
        self.isDemo = isDemo
        self.service = service
        refresh()
    }

    func refresh() {
        guard !isDemo, service.isAvailable else { return }
        status = service.status
    }

    func setEnabled(_ enabled: Bool) async {
        guard canChange else { return }
        isUpdating = true
        errorMessage = nil
        defer {
            refresh()
            isUpdating = false
        }
        // Re-read first: System Settings may have changed while the window was open.
        refresh()
        do {
            if enabled {
                switch status {
                case .enabled: return
                case .requiresApproval:
                    // Do not re-register an item disabled by the user in System Settings.
                    service.openSystemSettings()
                default: try service.register()
                }
            } else if status == .enabled || status == .requiresApproval {
                try await service.unregister()
            }
        } catch {
            errorMessage = "\(enabled ? "开启" : "关闭")自启动失败：\(error.localizedDescription)"
        }
    }

    func openSystemSettings() {
        guard canChange else { return }
        service.openSystemSettings()
    }
}
