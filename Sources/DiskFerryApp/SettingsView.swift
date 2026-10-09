import AppKit
import DiskFerryCore
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, disks, diagnostics, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "通用"
        case .disks: "磁盘"
        case .diagnostics: "诊断"
        case .about: "关于"
        }
    }
}

enum SettingsLayout {
    static let width: CGFloat = 560
    static let height: CGFloat = 520
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("设置分类", selection: $model.selectedPage) {
                ForEach(SettingsPage.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.regular)
            .frame(width: 260).padding(.top, 16).padding(.bottom, 12)
            if model.isDemo {
                Text("演示数据 · 磁盘操作已停用，偏好不会保存。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 8)
            }
            if let error = model.errorMessage {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Spacer()
                    Button("关闭") { model.errorMessage = nil }
                }.font(.callout).padding(.horizontal, 24).padding(.bottom, 10)
            }
            if model.selectedPage == .general {
                general
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch model.selectedPage {
                        case .general: EmptyView()
                        case .disks: disks
                        case .diagnostics: diagnostics
                        case .about: about
                        }
                    }.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.body)
        .controlSize(.small)
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("盘渡", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("好") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }

    private var general: some View {
        Form {
            Section("通用") {
                LoginItemSettingsRow(controller: model.loginItem)
                preferenceRow("自动读写 NTFS", help: model.backend.writeEngineQualified
                    ? "健康的外置 NTFS 磁盘接入后自动读写。"
                    : "读写组件尚未就绪，此偏好会在组件就绪后生效。",
                    value: $model.preferences.automaticWriting)
                preferenceRow("显示菜单栏图标", help: "隐藏后，重新打开盘渡可进入设置。", value: $model.preferences.showMenuBarIcon)
                preferenceRow("显示读写活动", help: "遵循减少动态效果设置；当前暂无活动信号。", value: $model.preferences.showActivity)
            }
            Section("更新") {
                preferenceRow("自动检查更新", help: "开发版暂无更新来源；安装前会询问并等待磁盘安全推出。", value: $model.preferences.checkForUpdates)
            }
        }.formStyle(.grouped)
    }

    private var disks: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("NTFS 磁盘").font(.headline)
                Spacer()
                refreshButton
            }
            if let error = model.scanError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            if let volume = model.selectedVolume {
                Picker("磁盘", selection: Binding(get: { volume.id }, set: { model.selectedVolumeID = $0 })) {
                    ForEach(model.volumes) { Text($0.name).tag($0.id) }
                }
                VStack(spacing: 10) {
                    detail("格式", volume.fileSystem.rawValue)
                    detail("当前状态", volume.statusLabel)
                    detail("连接", volume.busProtocol ?? "未知")
                    detail("位置", volume.mountPoint ?? "未挂载")
                    detail("容量", volume.totalBytes.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .decimal) } ?? "未知")
                }
                Divider()
                Picker("此磁盘策略", selection: Binding(get: { model.preferences.policy(for: volume) },
                                                      set: { model.setPolicy($0, for: volume) })) {
                    ForEach(VolumePolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .disabled(model.isDemo || volume.preferenceKey == nil)
                Text(volume.preferenceKey == nil ? "无法取得稳定的卷标识，暂不保存此磁盘的策略。"
                     : "按卷标识记住设置。读写组件就绪前，盘渡不会改变系统挂载方式。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("在 Finder 中打开") { Task { _ = await model.openVolume(volume) } }
                        .disabled(model.isDemo || volume.mountPoint == nil || !volume.hasSafeIdentity || model.ejectingDevice != nil)
                    Button(model.ejectingDevice == volume.id ? "正在推出…" : "安全推出") {
                        Task { _ = await model.eject(volume) }
                    }
                    .disabled(model.isDemo || !volume.hasSafeIdentity || volume.wholeDiskID == nil || model.ejectingDevice != nil)
                }
                Text("推出会同时卸载此物理磁盘上的所有分区；系统拒绝时不会强制推出。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                    Text(model.isScanning ? "正在读取磁盘信息…" : "未检测到外置 NTFS 磁盘").font(.headline)
                    Text("连接磁盘后，盘渡会自动更新状态。")
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 55)
            }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("系统与读写组件").font(.headline)
                Spacer()
                Button("刷新") { Task { await model.refreshDiagnostics() } }.disabled(model.isScanning)
            }
            detail("系统", "macOS \(model.environment.osVersion)")
            detail("芯片", model.environment.hardwareArchitecture == "arm64" ? "Apple Silicon" : "Intel")
            detail("FSKit", model.backendInspected ? (model.backend.fsKitAvailable ? "系统接口可用" : "需 macOS 15.4 或更新版本") : "正在查询…")
            detail("NTFS 读写", model.backend.writeEngineQualified ? "已验证" : "尚未就绪")
            Divider()
            Text("系统文件系统扩展").font(.callout.weight(.medium))
            if let error = model.backend.inspectionError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            } else if model.backend.modules.isEmpty {
                Text(model.backendInspected ? "未发现已安装的 FSKit 扩展。" : "正在查询…")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(model.backend.modules, id: \.bundleIdentifier) { module in
                    detail(module.bundleIdentifier, module.enabled ? "已启用" : "未启用")
                }
            }
            if let error = model.scanError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            ForEach(model.snapshot?.issues ?? []) { issue in
                Text("\(issue.device)：\(issue.message)").font(.caption).foregroundStyle(.orange)
            }
            Divider()
            Text("系统接口可用或发现扩展，不代表盘渡已经具备 NTFS 写入能力。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("导出诊断报告…") { model.exportReport() }.disabled(model.snapshot == nil)
                Spacer()
                if let date = model.snapshot?.scannedAt {
                    Text("更新于 \(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var about: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApplication.shared.applicationIconImage)
                .resizable().interpolation(.high).frame(width: 64, height: 64)
            Text("盘渡 DiskFerry").font(.title2.weight(.semibold))
            Text(DiskFerryVersion.current).font(.callout).foregroundStyle(.secondary)
            Text("让文件，自由靠岸。").font(.body)
            Divider().padding(.vertical, 8)
            Text("原生菜单栏开发版\n已支持磁盘识别、状态查看与安全推出。\nNTFS 写入正在进行技术验证，暂未开放。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
        }.frame(maxWidth: .infinity).padding(.top, 16)
    }

    private var refreshButton: some View {
        Button("刷新") { Task { await model.refresh() } }.disabled(model.isScanning || model.ejectingDevice != nil)
    }

    private func preferenceRow(_ title: String, help: String, value: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: value).toggleStyle(.checkbox).controlSize(.regular)
                .accessibilityHint(help)
            Text(help).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.leading, 20)
        }.padding(.vertical, 2)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 20) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.callout)
    }
}
