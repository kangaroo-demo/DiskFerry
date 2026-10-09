import SwiftUI

struct LoginItemSettingsRow: View {
    @ObservedObject var controller: LoginItemController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("开机自启动", isOn: Binding(get: { controller.isEnabled },
                                                set: { enabled in Task { await controller.setEnabled(enabled) } }))
                    .toggleStyle(.checkbox).controlSize(.regular)
                    .accessibilityHint(controller.help)
                    .disabled(!controller.canChange)
                Spacer()
                Button("登录项设置…") { controller.openSystemSettings() }
                    .disabled(!controller.canChange).controlSize(.small)
            }
            Text(controller.help).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.leading, 20)
            if controller.requiresApproval {
                Button("移除待批准的登录项") { Task { await controller.setEnabled(false) } }
                    .disabled(!controller.canChange).padding(.leading, 20).controlSize(.small)
            }
            if let error = controller.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 20)
            }
        }.padding(.vertical, 2)
    }
}
