import AppKit
import SwiftUI

struct HotKeySettings: View {
    @ObservedObject var controller: GlobalHotKeyController
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("全局快捷键").font(.system(size: 13))
                Spacer()
                Toggle("启用全局快捷键", isOn: Binding(get: { controller.configuration.enabled }, set: { controller.setEnabled($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            HStack {
                HotKeyRecorder(controller: controller).frame(width: 154, height: 28)
                Spacer(minLength: 4)
                Button("恢复默认") { controller.restoreDefault() }.controlSize(.small)
            }
            Text(controller.recording ? "按 Esc 或点击其他位置取消。至少搭配 ⌘、⌥ 或 ⌃。" : "后台驻留时展开或收起启动台；完全退出后不生效。")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = controller.error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                if controller.configuration.enabled && !controller.registered && !controller.recording {
                    Button("重试启用") { controller.setEnabled(true) }.controlSize(.small)
                }
            }
        }
        .onDisappear { controller.cancelRecording() }
    }
}

private struct HotKeyRecorder: NSViewRepresentable {
    @ObservedObject var controller: GlobalHotKeyController
    func makeNSView(context: Context) -> HotKeyRecorderButton {
        let button = HotKeyRecorderButton()
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12)
        button.controller = controller
        button.target = button; button.action = #selector(HotKeyRecorderButton.beginRecording)
        button.setAccessibilityLabel("录入全局快捷键")
        return button
    }
    func updateNSView(_ button: HotKeyRecorderButton, context: Context) {
        button.title = controller.recording ? "请按下快捷键" : controller.configuration.shortcut.display
        button.toolTip = "点击录入快捷键"
        button.setAccessibilityValue(button.title)
    }
}

final class HotKeyRecorderButton: NSButton {
    weak var controller: GlobalHotKeyController?
    override var acceptsFirstResponder: Bool { true }
    @objc func beginRecording() {
        window?.makeFirstResponder(self)
        controller?.beginRecording()
    }
    override func resignFirstResponder() -> Bool {
        controller?.cancelRecording()
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        if controller?.recording == true { controller?.record(event) }
        else { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard controller?.recording == true else { return super.performKeyEquivalent(with: event) }
        controller?.record(event)
        return true
    }
}
