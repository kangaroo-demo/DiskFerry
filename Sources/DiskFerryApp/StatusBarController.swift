import AppKit
import Combine
import DiskFerryCore

@MainActor
private final class ActionMenuItem: NSMenuItem {
    var handler: (() -> Void)?
}

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let showSettings: (SettingsPage) -> Void
    private var item: NSStatusItem?
    private var subscription: AnyCancellable?
    private var visibilityObserver: NSKeyValueObservation?
    private var tracking = false
    var isVisible: Bool { item?.isVisible == true }

    /// Exercise AppKit action dispatch after menu tracking closes and queued updates run.
    /// Used only by the explicit, isolated UI smoke test.
    func performSmokeMenuSelection(title: String) async -> Bool {
        guard let menu = item?.menu else { return false }
        menuWillOpen(menu)
        guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
            menuDidClose(menu)
            return false
        }
        let selected = menu.items[index]
        menuDidClose(menu)
        try? await Task.sleep(for: .milliseconds(120))
        let targetSurvived = selected.target != nil
        menu.performActionForItem(at: index)
        return targetSurvived
    }

    init(model: AppModel, showSettings: @escaping (SettingsPage) -> Void) {
        self.model = model
        self.showSettings = showSettings
        super.init()
        rebuild()
        subscription = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        populate(menu)
        tracking = true
        Task { await model.refresh() }
    }
    func menuDidClose(_ menu: NSMenu) {
        tracking = false
        Task { @MainActor [weak self] in self?.rebuild() }
    }

    private func rebuild() {
        guard !tracking else { return }
        if !model.preferences.showMenuBarIcon {
            visibilityObserver = nil
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        if item == nil {
            let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            status.behavior = [.removalAllowed]
            let icon = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "盘渡")
            icon?.isTemplate = true
            status.button?.image = icon
            status.button?.toolTip = "盘渡 DiskFerry"
            item = status
            visibilityObserver = status.observe(\.isVisible, options: [.new]) { [weak self] _, change in
                guard change.newValue == false else { return }
                Task { @MainActor in self?.model.preferences.showMenuBarIcon = false }
            }
        }
        let menu = NSMenu(title: "盘渡")
        menu.delegate = self
        menu.autoenablesItems = false
        populate(menu)
        item?.menu = menu
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(model.isDemo ? "盘渡 · 演示数据" : "盘渡", to: menu, enabled: false)
        if model.volumes.isEmpty {
            add(model.scanError != nil ? "磁盘查询失败，请打开诊断" : (model.isScanning ? "正在读取磁盘…" : "未检测到外置 NTFS 磁盘"), to: menu, enabled: false)
        } else if model.volumes.count == 1, let volume = model.volumes.first {
            addVolume(volume, to: menu)
        } else {
            for volume in model.volumes {
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                addVolume(volume, to: submenu)
                let parent = NSMenuItem(title: "\(displayName(volume)) · \(volume.statusLabel)", action: nil, keyEquivalent: "")
                parent.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
                parent.submenu = submenu
                menu.addItem(parent)
            }
        }
        menu.addItem(.separator())
        add("设置…", symbol: "gearshape", to: menu) { [weak self] in self?.showSettings(.general) }
        add("关于盘渡", symbol: "info.circle", to: menu) { [weak self] in self?.showSettings(.about) }
        menu.addItem(.separator())
        add("退出盘渡", to: menu) { NSApp.terminate(nil) }
    }

    private func addVolume(_ volume: Volume, to menu: NSMenu) {
        add(displayName(volume), symbol: "externaldrive", to: menu, enabled: false)
        add("NTFS · \(volume.statusLabel)", to: menu, enabled: false)
        let idle = model.ejectingDevice == nil && !model.isDemo
        add("在 Finder 中打开", symbol: "folder", to: menu,
            enabled: idle && volume.mountPoint != nil && volume.hasSafeIdentity) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if !(await self.model.openVolume(volume)) { self.presentError() }
            }
        }
        add(model.ejectingDevice == volume.id ? "正在推出…" : "安全推出 \(displayName(volume))", symbol: "eject", to: menu,
            enabled: idle && volume.hasSafeIdentity && volume.wholeDiskID != nil) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if !(await self.model.eject(volume)) { self.presentError() }
            }
        }
        add("将推出整块磁盘及其所有分区", to: menu, enabled: false)
        menu.addItem(.separator())
        add("磁盘设置…", symbol: "gearshape", to: menu) { [weak self] in
            self?.model.selectedVolumeID = volume.id
            self?.showSettings(.disks)
        }
    }

    private func displayName(_ volume: Volume) -> String {
        String(volume.name.components(separatedBy: .newlines).joined(separator: " ").prefix(60))
    }

    private func add(_ title: String, symbol: String? = nil, to menu: NSMenu,
                     enabled: Bool = true, action: (() -> Void)? = nil) {
        let entry: NSMenuItem
        if let action {
            let actionable = ActionMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
            actionable.handler = action
            actionable.target = self
            entry = actionable
        } else {
            entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        }
        entry.isEnabled = enabled
        if let symbol { entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(entry)
    }

    // AppKit may dispatch a selection after menuDidClose and a refresh. The
    // controller stays alive; each sender keeps its own action across rebuilds.
    @objc private func performMenuAction(_ sender: NSMenuItem) {
        (sender as? ActionMenuItem)?.handler?()
    }

    private func presentError() {
        guard let error = model.errorMessage else { return }
        let alert = NSAlert()
        alert.messageText = "盘渡未能完成操作"
        alert.informativeText = error
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        model.errorMessage = nil
    }
}
