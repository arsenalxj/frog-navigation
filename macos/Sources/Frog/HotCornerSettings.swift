import SwiftUI

struct HotCornerSettings: View {
    @ObservedObject var controller: HotCornerController
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("屏幕触角").font(.system(size: 13))
                Spacer()
                Toggle("启用屏幕触角", isOn: Binding(get: { controller.configuration.enabled }, set: { controller.setEnabled($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            Picker("触发角落", selection: Binding(get: { controller.configuration.corner }, set: { controller.setCorner($0) })) {
                ForEach(ScreenCorner.allCases, id: \.self) { corner in Text(corner.title).tag(corner) }
            }
            .pickerStyle(.menu).controlSize(.small).font(.system(size: 12))
            .disabled(!controller.configuration.enabled)
            Text("鼠标触碰所选角落立即展开，移开后可再次触发。")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("如与 macOS 系统触发角重叠，可能同时触发；可更换角落或在系统设置中调整。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = controller.error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("重试启用") { controller.retry() }.controlSize(.small)
            }
        }
    }
}
