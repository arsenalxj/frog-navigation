import AppKit
import FrogCore
import SwiftUI

struct PanelSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency { RoundedRectangle(cornerRadius: radius).fill(Color(nsColor: .windowBackgroundColor)) }
                else { RoundedRectangle(cornerRadius: radius).fill(.regularMaterial) }
            }
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(.primary.opacity(0.12), lineWidth: 0.6))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .shadow(color: .black.opacity(0.32), radius: 34, y: 18)
    }
}

struct PanelField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var initialFocus = false
    var onSubmit: (() -> Void)?
    var focusToken: Int? = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            textField
                .textFieldStyle(.plain).font(.system(size: 13.5))
                .padding(.horizontal, 11).frame(height: 34)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.14), lineWidth: 0.7))
                .accessibilityLabel(title)
        }
    }
    @ViewBuilder private var textField: some View {
        if initialFocus {
            InitialFocusTextField(placeholder: placeholder, text: $text, label: title,
                                  onSubmit: onSubmit, focusToken: focusToken)
                .fixedSize(horizontal: false, vertical: true)
        }
        else { TextField(placeholder, text: $text) }
    }
}

/// 首次焦点依赖实际挂载、可编辑与 key window 状态；成功后不再主动抢焦点。
struct InitialFocusTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let label: String
    var font = NSFont.systemFont(ofSize: 13.5)
    var color = NSColor.labelColor
    var alignment = NSTextAlignment.left
    var onSubmit: (() -> Void)?
    var focusToken: Int? = 0
    @Environment(\.isEnabled) private var enabled

    func makeNSView(context: Context) -> FirstFocusField {
        let field = FirstFocusField()
        field.isBordered = false; field.isBezeled = false; field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true; field.isSelectable = true
        field.cell?.usesSingleLineMode = true
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        return field
    }
    func updateNSView(_ field: FirstFocusField, context: Context) {
        context.coordinator.parent = self
        field.font = font; field.textColor = color; field.alignment = alignment
        field.placeholderString = placeholder
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: color.withAlphaComponent(0.55), .font: font])
        field.setAccessibilityLabel(label)
        field.diagnosticLabel = label
        field.isEnabled = enabled
        if field.stringValue != text { field.stringValue = text }
        field.requestFocus(token: focusToken)
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InitialFocusTextField
        init(_ parent: InitialFocusTextField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            Diagnostics.emit("focus_began", details: ["field": parent.label])
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            Diagnostics.emit("focus_ended", details: ["field": parent.label])
        }
        @objc func submit() { parent.onSubmit?() }
    }
}

final class FirstFocusField: NSTextField {
    var diagnosticLabel = ""
    private var pendingInitialFocus = false
    private var lastRequestedToken: Int?
    private var focusScheduled = false
    private var keyObserver: NSObjectProtocol?
    private var updateObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver); self.keyObserver = nil }
        if let updateObserver { NotificationCenter.default.removeObserver(updateObserver); self.updateObserver = nil }
        if let window {
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.scheduleInitialFocus()
            }
            updateObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
                self?.scheduleInitialFocus()
            }
        }
        scheduleInitialFocus()
    }
    func requestFocus(token: Int?) {
        if token == nil, let editor = currentEditor(), window?.firstResponder === editor {
            // 只释放本控件仍持有的 field editor，避免清除新弹窗已经取得的焦点。
            window?.makeFirstResponder(nil)
        }
        if token != lastRequestedToken {
            lastRequestedToken = token
            pendingInitialFocus = token != nil
            if token != nil {
                Diagnostics.emit("focus_requested", details: ["field": diagnosticLabel, "enabled": isEnabled, "mounted": window != nil])
            }
        }
        scheduleInitialFocus()
    }
    func scheduleInitialFocus() {
        guard pendingInitialFocus, !focusScheduled, isEnabled, window?.isKeyWindow == true else { return }
        focusScheduled = true
        // 下一轮主事件循环在 SwiftUI 完成本次挂载和释放搜索焦点之后执行；不按时间猜测。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.pendingInitialFocus, self.isEnabled, let window = self.window, window.isKeyWindow else { self.focusScheduled = false; return }
            let accepted = window.makeFirstResponder(self)
            Diagnostics.emit("focus_attempt", details: ["field": self.diagnosticLabel, "accepted": accepted, "has_editor": self.currentEditor() != nil])
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self else { return }
                self.focusScheduled = false
                let confirmed = self.currentEditor() != nil && self.currentEditor() === window?.firstResponder
                if confirmed { self.pendingInitialFocus = false }
                Diagnostics.emit("focus_verified", details: ["field": self.diagnosticLabel, "focused": confirmed])
            }
        }
    }
    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
    }
}

struct PanelButtonStyle: ButtonStyle {
    var primary = false
    var destructive = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16).frame(height: 30)
            .foregroundStyle(primary || destructive ? Color.white : Color.primary)
            .background(destructive ? Color.red : primary ? Color.accentColor : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(primary || destructive ? 0 : 0.12), lineWidth: 0.6))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

struct LocationChoice: Equatable {
    let id: String
    let title: String
}

struct LocationPopUp: NSViewRepresentable {
    let choices: [LocationChoice]
    @Binding var selection: String
    @Environment(\.isEnabled) private var enabled

    func makeNSView(context: Context) -> LocationPopUpButton {
        let button = LocationPopUpButton(frame: .zero, pullsDown: false)
        let cell = LocationPopUpCell(textCell: "", pullsDown: false)
        cell.arrowPosition = .noArrow
        cell.alignment = .left
        cell.altersStateOfSelectedItem = true
        button.cell = cell
        button.isBordered = false
        button.focusRingType = .none
        button.font = .systemFont(ofSize: 13.5)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setAccessibilityLabel("位置")
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        return button
    }

    func updateNSView(_ button: LocationPopUpButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = enabled
        let missing = !choices.contains(where: { $0.id == selection })
        let displayed = missing ? [LocationChoice(id: selection, title: "请选择位置")] + choices : choices
        if context.coordinator.displayed != displayed {
            let menu = NSMenu(title: "位置")
            menu.autoenablesItems = false
            for choice in displayed {
                if choice.id == "__new__" { menu.addItem(.separator()) }
                let item = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
                item.representedObject = choice.id
                item.isEnabled = !missing || choice.id != selection
                menu.addItem(item)
            }
            button.menu = menu
            context.coordinator.displayed = displayed
        }
        for item in button.itemArray {
            let selected = item.representedObject as? String == selection
            item.state = selected ? .on : .off
            if selected { button.select(item) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject {
        var parent: LocationPopUp
        var displayed: [LocationChoice] = []
        init(_ parent: LocationPopUp) { self.parent = parent }
        @objc func choose(_ sender: NSPopUpButton) {
            if let id = sender.selectedItem?.representedObject as? String { parent.selection = id }
        }
    }
}

final class LocationPopUpButton: NSPopUpButton {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 34) }
}

final class LocationPopUpCell: NSPopUpButtonCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var title = super.titleRect(forBounds: rect)
        title.origin.x = rect.minX + 11
        title.size.width = max(0, rect.width - 37)
        return title
    }
}

struct BookmarkEditorPanel: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var store: BookmarkStore
    private var busy: Bool { model.savingDraft || store.isBusy }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.draft.id == nil ? "添加书签" : "编辑书签")
                .font(.system(size: 16, weight: .bold)).padding(.bottom, 18)
            VStack(spacing: 14) {
                PanelField(title: "网址", placeholder: "example.com 或 https://example.com", text: $model.draft.url,
                           initialFocus: true, onSubmit: { model.saveDraft() }, focusToken: model.editorFocusToken)
                PanelField(title: "标题", placeholder: "书签名称（≤ 120 字）", text: $model.draft.title)
                VStack(alignment: .leading, spacing: 6) {
                    Text("位置").font(.system(size: 12)).foregroundStyle(.secondary)
                    LocationPopUp(choices: locationChoices, selection: $model.draft.location)
                        .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .trailing) {
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                .padding(.trailing, 11).allowsHitTesting(false)
                        }
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.14), lineWidth: 0.7).allowsHitTesting(false))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if model.draft.location == "__new__" { PanelField(title: "新文件夹名称", placeholder: "例如：工作", text: $model.draft.newFolderName) }
            }
            .disabled(busy)
            if let error = model.draft.error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("取消") { model.showEditor = false; model.focusRequest += 1 }.buttonStyle(PanelButtonStyle()).disabled(busy)
                Button(busy ? "正在保存…" : model.draft.id == nil ? "添加" : "保存") { model.saveDraft() }
                    .buttonStyle(PanelButtonStyle(primary: true)).keyboardShortcut(.defaultAction).disabled(busy)
            }.padding(.top, 20)
        }
        .padding(24).frame(width: 420).modifier(PanelSurface())
        .disabled(model.editorFocusToken == nil)
    }

    private var locationChoices: [LocationChoice] {
        [LocationChoice(id: "__root__", title: "根目录")]
            + store.document.groups.sorted { $0.order < $1.order }.map { LocationChoice(id: $0.id, title: $0.name) }
            + [LocationChoice(id: "__new__", title: "＋ 新建文件夹…")]
    }
}

enum SettingsTab: String, CaseIterable {
    case general = "通用"
    case data = "数据与备份"
    case about = "关于"
    var symbol: String { switch self { case .general: return "gearshape"; case .data: return "externaldrive"; case .about: return "info.circle" } }
}

struct SettingsPanel: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var store: BookmarkStore
    @ObservedObject var login: LoginItemController
    @State private var tab: SettingsTab = .general
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Button { model.showSettings = false; model.focusRequest += 1 } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.primary.opacity(0.65))
                            .frame(width: 13, height: 13).background(.primary.opacity(0.13), in: Circle())
                    }.buttonStyle(.plain).help("关闭设置").accessibilityLabel("关闭设置")
                    Spacer()
                }.padding(.horizontal, 6).padding(.bottom, 14)
                ForEach(SettingsTab.allCases, id: \.self) { item in
                    Button { tab = item } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.symbol).font(.system(size: 14)).frame(width: 16)
                            Text(item.rawValue).font(.system(size: 13))
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 10).frame(height: 30)
                            .foregroundStyle(tab == item ? Color.white : Color.primary)
                            .background(tab == item ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 10).padding(.vertical, 16).frame(width: 168)
            .background(.primary.opacity(0.025))
            Rectangle().fill(.primary.opacity(0.1)).frame(width: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(tab.rawValue).font(.system(size: 19, weight: .bold)).padding(.bottom, 2)
                    switch tab {
                    case .general: general
                    case .data: data
                    case .about: about
                    }
                }.padding(.horizontal, 24).padding(.vertical, 22).frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.hidden)
        }
        .frame(width: 560, height: min(tab == .general ? 640 : (tab == .data ? 490 : 300), model.metrics.size.height * 0.78))
        .modifier(PanelSurface(radius: 14))
        .onAppear { login.refresh() }
        .onChange(of: tab) { _, _ in model.hotKey?.cancelRecording() }
        .onDisappear { model.hotKey?.cancelRecording() }
    }

    private var general: some View {
        Group {
            settingGroup {
                HStack(spacing: 12) {
                    Text("登录时启动").font(.system(size: 13))
                    Spacer()
                    Toggle("登录时启动", isOn: Binding(get: { login.enabled || login.requiresApproval }, set: { login.setEnabled($0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small).disabled(login.changing)
                }
                Text(login.requiresApproval ? "等待系统批准。请在登录项设置中允许青蛙导航。" : "登录后静默驻留，可通过程序坞图标、快捷键或屏幕触角展开。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if login.requiresApproval { Button("打开系统登录项设置") { login.openSettings() }.controlSize(.small) }
                if let error = login.error {
                    Text(error).font(.system(size: 11.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Button("打开系统登录项设置") { login.openSettings() }.controlSize(.small)
                }
            }
            if let hotKey = model.hotKey {
                settingGroup { HotKeySettings(controller: hotKey) }
            }
            if let hotCorner = model.hotCorner {
                settingGroup { HotCornerSettings(controller: hotCorner) }
            }
            if let finderJump = model.finderJump {
                settingGroup { FinderJumpSettings(controller: finderJump) }
            }
            settingGroup {
                shortcut("设置", key: "⌘ ,")
                Divider()
                shortcut("收起 / 返回", key: "Esc")
                Divider()
                shortcut("翻页", key: "⌘ ← / →")
            }
        }
    }

    private var data: some View {
        Group {
            settingGroup {
                Text("数据目录").font(.system(size: 13))
                Text(store.directory.path).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer()
                    Button("在 Finder 中打开") { NSWorkspace.shared.open(store.directory) }.controlSize(.small)
                    Button("选择目录…") { model.chooseDirectory() }.controlSize(.small).disabled(store.isBusy)
                }
            }
            settingGroup {
                HStack { Text("另存备份").font(.system(size: 13)); Spacer(); Button("导出 JSON…") { model.exportBackup() }.controlSize(.small).disabled(store.isBusy) }
                Text("将全部书签与文件夹保存为 JSON 副本，当前数据目录保持不变。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            settingGroup {
                HStack { Text("恢复备份").font(.system(size: 13)); Spacer(); Button("选择备份…") { model.restoreBackup() }.controlSize(.small).disabled(store.isBusy) }
                Text("恢复后将替换当前数据目录中的全部书签和分组。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("同步目录中的恢复结果，也会由你的同步工具继续同步。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var about: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().scaledToFit().frame(width: 58, height: 58)
            VStack(spacing: 4) {
                Text("青蛙导航").font(.system(size: 15, weight: .bold))
                Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text("本地书签启动台。\n书签与分组保存在你选择的数据目录中，\n网站图标缓存在本机，随时可以备份与恢复。")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4).padding(.top, 4)
        }.frame(maxWidth: .infinity)
    }

    private func shortcut(_ label: String, key: String) -> some View {
        HStack { Text(label); Spacer(); Text(key).foregroundStyle(.secondary) }.font(.system(size: 12))
    }
    private func settingGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9, content: content).padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.12), lineWidth: 0.7))
    }
}

struct DeletePanel: View {
    @ObservedObject var model: LauncherModel
    let target: LaunchItem
    let busy: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("删除“\(target.title)”？").font(.system(size: 16, weight: .bold)).lineLimit(3)
            Text("删除后将从当前书签数据中移除，无法直接撤销。")
                .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button("取消") { model.deleteTarget = nil }.buttonStyle(PanelButtonStyle())
                Button("删除", role: .destructive) { model.confirmDelete() }.buttonStyle(PanelButtonStyle(destructive: true)).disabled(busy)
            }.padding(.top, 5)
        }.padding(24).frame(width: 420).modifier(PanelSurface())
    }
}

struct RenamePanel: View {
    @ObservedObject var model: LauncherModel
    let busy: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("重命名文件夹").font(.system(size: 16, weight: .bold))
            PanelField(title: "名称", placeholder: "文件夹名称", text: $model.renameText,
                       initialFocus: true, onSubmit: { model.saveRename() }, focusToken: model.renameFocusToken)
            if let error = model.renameError { Text(error).font(.system(size: 11.5)).foregroundStyle(.red) }
            HStack(spacing: 10) {
                Spacer()
                Button("取消") { model.renamingID = nil }.buttonStyle(PanelButtonStyle())
                Button("保存") { model.saveRename() }.buttonStyle(PanelButtonStyle(primary: true)).keyboardShortcut(.defaultAction).disabled(busy)
            }.padding(.top, 5)
        }.padding(24).frame(width: 420).modifier(PanelSurface())
    }
}
