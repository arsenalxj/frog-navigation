import SwiftUI

struct FinderJumpSettings: View {
    @ObservedObject var controller: FinderJumpController

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Text("Finder 目录快跳").font(.system(size: 13))
                Spacer()
                Toggle("Finder 目录快跳", isOn: Binding(get: { controller.enabled }, set: { controller.setEnabled($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            Text("选择文件时，点击目录入口或按 ⌃G 前往 Finder 最后活动的文件夹。")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if controller.enabled {
                if controller.checkingPermissions {
                    Text("正在检查权限…")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else {
                    if !controller.permissions.canNavigate {
                        Text("请授权后使用，返回后自动检查。")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    if let missing = controller.permissions.missing.first {
                        Button(missing.buttonTitle) { controller.requestPermission(missing) }
                            .controlSize(.small).disabled(controller.requestingPermission)
                    }
                    if let error = controller.permissions.finderAutomationError {
                        Text(error).font(.system(size: 11.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        Button("重新检查授权") { controller.refresh() }.controlSize(.small)
                    }
                }
                if controller.shortcutConflict {
                    Text("⌃G 已用于展开启动台。请调整启动台快捷键；目录入口仍可点击。")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let error = controller.error {
                    Text(error).font(.system(size: 11.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Button("重试") { controller.refresh() }.controlSize(.small)
                }
            }
        }
        .onAppear { controller.refresh() }
    }
}
