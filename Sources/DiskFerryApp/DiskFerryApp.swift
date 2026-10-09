import AppKit
import SwiftUI

@main
struct DiskFerryApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var statusBar: StatusBarController!
    private var settingsWindow: NSWindow?
    private var refreshTask: Task<Void, Never>?
    private var eventObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model = AppModel(isDemo: CommandLine.arguments.contains("--demo") || smokeDirectory != nil || loginItemVerificationDirectory != nil)
        buildMainMenu()
        statusBar = StatusBarController(model: model) { [weak self] page in self?.showSettings(page) }
        for event in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didWakeNotification] {
            eventObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: event, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.model.refresh() }
            })
        }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await model.start()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
                await model.refresh()
            }
        }
        if let directory = loginItemVerificationDirectory {
            Task { await verifyLoginItem(directory: directory) }
        } else if let directory = smokeDirectory {
            Task { await runSmokeTest(directory: directory) }
        } else if CommandLine.arguments.contains("--settings") {
            showSettings(.general)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidBecomeActive(_ notification: Notification) { model?.loginItem.refresh() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(.general)
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        refreshTask?.cancel()
        for observer in eventObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func showSettings(_ page: SettingsPage) {
        model.loginItem.refresh()
        model.selectedPage = page
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsLayout.width, height: SettingsLayout.height),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "盘渡设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings() { showSettings(.general) }
    @objc private func openAbout() { showSettings(.about) }

    private func buildMainMenu() {
        let root = NSMenu()
        let appMenu = NSMenu(title: "盘渡")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        root.addItem(appItem)
        for (title, action, key) in [("关于盘渡", #selector(openAbout), ""),
                                    ("设置…", #selector(openSettings), ",")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            appMenu.addItem(item)
        }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出盘渡", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "编辑")
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        root.addItem(editItem)
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = root
    }

    private var smokeDirectory: String? {
        argumentValue(for: "--smoke-test")
    }

    private var loginItemVerificationDirectory: String? {
        argumentValue(for: "--verify-login-item")
    }

    private func argumentValue(for option: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: option),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    /// Explicit development check: register, inspect, then remove the main-app login item.
    /// An existing user configuration is left alone, and normal UI smoke tests never register.
    private func verifyLoginItem(directory: String) async {
        let service = SystemLoginItemService()
        let controller = LoginItemController(isDemo: false, service: service)
        var result: [String: Any] = ["available": service.isAvailable, "initialStatus": controller.status.rawValue]
        if (controller.status == .notRegistered || controller.status == .notFound) && service.isAvailable {
            await controller.setEnabled(true)
            result["registeredStatus"] = controller.status.rawValue
            result["registrationError"] = controller.errorMessage
            let registered = controller.isEnabled
            await controller.setEnabled(false)
            result["removalError"] = controller.errorMessage
            result["restoredStatus"] = controller.status.rawValue
            let restored = controller.status == .notRegistered || controller.status == .notFound
            result["restored"] = restored
            result["passed"] = registered && restored
        } else {
            result["skipped"] = "登录项已经配置，或当前不是应用包；未修改现有系统设置。"
        }
        do {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: url.appendingPathComponent("login-item.json"))
        } catch {
            FileHandle.standardError.write(Data("Login item verification: \(error)\n".utf8))
        }
        NSApp.terminate(nil)
    }

    /// This explicit development mode uses isolated preferences and never mutates disks.
    private func runSmokeTest(directory: String) async {
        do {
            if CommandLine.arguments.contains("--appearance-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try await Task.sleep(for: .milliseconds(700))
            // AppKit includes its private status/menu windows in NSApp.windows.
            let startupCount = NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }.count
            let dockHidden = NSApp.activationPolicy() == .accessory
            let statusVisible = statusBar.isVisible
            let settingsTargetSurvived = await statusBar.performSmokeMenuSelection(title: "设置…")
            try await Task.sleep(for: .milliseconds(150))
            let settingsOpenedFromMenu = settingsTargetSurvived && settingsWindow?.isVisible == true && model.selectedPage == .general
            settingsWindow?.close()
            let aboutTargetSurvived = await statusBar.performSmokeMenuSelection(title: "关于盘渡")
            try await Task.sleep(for: .milliseconds(150))
            let aboutOpenedFromMenu = aboutTargetSurvived && settingsWindow?.isVisible == true && model.selectedPage == .about
            settingsWindow?.close()
            for page in SettingsPage.allCases {
                showSettings(page)
                try await Task.sleep(for: .milliseconds(550))
                guard let view = settingsWindow?.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try png.write(to: url.appendingPathComponent("settings-\(page.rawValue).png"))
                if let frame = view.superview, let windowBitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                    frame.cacheDisplay(in: frame.bounds, to: windowBitmap)
                    if let image = windowBitmap.representation(using: .png, properties: [:]) {
                        try image.write(to: url.appendingPathComponent("window-\(page.rawValue).png"))
                    }
                }
            }
            settingsWindow?.close()
            try await Task.sleep(for: .milliseconds(250))
            let closeCount = NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }.count
            model.preferences.showMenuBarIcon = false
            try await Task.sleep(for: .milliseconds(150))
            let hidden = !statusBar.isVisible
            model.preferences.showMenuBarIcon = true
            try await Task.sleep(for: .milliseconds(150))
            let restored = statusBar.isVisible
            let result: [String: Any] = ["startupVisibleWindows": startupCount, "dockHidden": dockHidden,
                "statusVisible": statusVisible, "visibleWindowsAfterClose": closeCount,
                "appSurvivedClose": true, "iconCanHide": hidden, "iconCanRestore": restored,
                "settingsOpenedFromMenu": settingsOpenedFromMenu, "aboutOpenedFromMenu": aboutOpenedFromMenu,
                "demoIsolated": model.isDemo, "pagesCaptured": SettingsPage.allCases.count,
                "passed": startupCount == 0 && dockHidden && statusVisible && closeCount == 0 && hidden && restored && settingsOpenedFromMenu && aboutOpenedFromMenu]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: url.appendingPathComponent("smoke.json"))
        } catch {
            FileHandle.standardError.write(Data("UI smoke test: \(error)\n".utf8))
        }
        NSApp.terminate(nil)
    }
}
