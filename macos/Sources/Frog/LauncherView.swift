import AppKit
import Combine
import FrogCore

@MainActor
final class LauncherView: NSView, NSTextFieldDelegate {
    let model: LauncherModel
    let input = NSTextField()
    private var observation: AnyCancellable?
    private var refreshQueued = false
    private var inputRevision = -1
    private var savedSelection: NSRange?
    private var savedRevision = -1
    private var wheelRemainder: CGFloat = 0
    private var dragSource: String?
    private var dragStart = NSPoint.zero
    private var dragging = false
    private var dropTarget: DropTarget?
    private var mergeReady = false
    private var mergeDelay: DispatchWorkItem?
    private var accessibilityRows: [TerminalAccessibilityElement] = []
    private var tooltipText: [NSView.ToolTipTag: String] = [:]
    private var accessibilityNeedsRefresh = true
    var regions: [Region] = []

    enum UIAction {
        case add, mkdir, edit, move, deleteSelection, copy, toggleOrganizing, toggleAllExpanded,
             openSettings, openHelp, activate, search, startCommand, escape,
             submitPrompt, savePrompt, confirmDelete, switchField, togglePromptChoices,
             focusCalcHistory, loadCalcHistory, copyCalc, clearCalc, deleteCalcHistory,
             submitCalc, focusSearchList, openSearch
    }

    struct ShortcutHint {
        let key: String
        let label: String
        let action: Action?
    }

    enum Action {
        case item(Int), delete(Int), toggle(Int), choice(Int), promptField(String),
             complete(String), draft(String), command(String), calcRow(Int),
             custom(CustomCommandAction), ui(UIAction), input
    }
    struct Region {
        let rect: NSRect
        let label: String
        let action: Action?
        var selected = false
    }
    private struct DropTarget: Equatable {
        let id: String?
        let before: Bool
        let merge: Bool
        let row: Int?
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var scale: CGFloat { max(0.01, min(bounds.width / 1440, bounds.height / 900)) }
    var canvasOrigin: NSPoint { NSPoint(x: (bounds.width - 1440 * scale) / 2, y: (bounds.height - 900 * scale) / 2) }
    var rowsTop: CGFloat { 24 }

    init(model: LauncherModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.textColor = TerminalDrawing.ink
        input.backgroundColor = .clear
        input.isEditable = true
        input.isSelectable = true
        input.lineBreakMode = .byClipping
        input.usesSingleLineMode = true
        input.cell?.isScrollable = true
        input.delegate = self
        input.setAccessibilityLabel("命令行输入")
        input.isHidden = true
        addSubview(input)
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
        setAccessibilityLabel("青蛙导航 回声终端")
        observation = Publishers.Merge(model.objectWillChange, model.store.objectWillChange).sink { [weak self] _ in
            guard let self, !self.refreshQueued else { return }
            self.refreshQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshQueued = false
                self.synchronize()
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        accessibilityNeedsRefresh = true
        layoutInput()
        needsDisplay = true
    }

    static let calcLabel = "算式"

    private var inputX: CGFloat {
        if let prompt = model.prompt { return min(480, 70 + TerminalDrawing.width(prompt.label, size: 13)) }
        if model.buffer == .calc, model.inputKind == .calc {
            return 70 + TerminalDrawing.width(Self.calcLabel, size: 13)
        }
        return 58
    }

    private var inputAccessibilityHelp: String {
        if model.buffer == .commands, model.isCommandsEditing, model.inputKind != .command { return model.customKeyboardHint }
        if let prompt = model.prompt { return prompt.error ?? prompt.keyboardHint }
        if model.buffer == .calc, model.calcHistoryFocused, model.inputKind != .command {
            return model.calcFeedback ?? "Enter 载入 · ⌘C 复制 · Esc 返回草稿"
        }
        switch model.inputKind {
        case .search:
            if model.buffer == .commands { return "↑↓ 选择 · Tab 进列表 · Enter 运行 · Esc 清空" }
            let navigation = model.items.isEmpty ? "" : "↑↓ 选择 · Tab 进列表 · "
            return navigation + "Enter \(model.searchAction.title) · Esc 清空"
        case .command: return "Tab 补全 · ↑↓ 选择 · ⌥↑↓ 历史 · Esc 取消"
        case .calc: return model.calcFeedback ?? "Enter 计算 · Tab 历史 · ⌘C 复制 · Esc 返回"
        default: return ""
        }
    }

    private var activeInputPlaceholder: String? {
        guard model.isTextInputActive, model.inputText.isEmpty else { return nil }
        if let prompt = model.prompt {
            if prompt.command == "commands-edit" {
                switch model.customField {
                case .name: return "例如 aiomp（字母开头，仅含字母/数字/-/_）"
                case .title: return "输入命令显示名称"
                case .directory: return "输入路径，⌘↓ 浏览目录"
                case .target:
                    switch model.customDraft?.type {
                    case .url: return "例如 https://github.com/search?q={query}"
                    case .program: return "可执行文件绝对路径或 ~/ 路径"
                    default: return "输入要在终端执行的命令"
                    }
                case .arguments: return "可选，使用 {args} 接收参数"
                default: return nil
                }
            }
            switch prompt.field {
            case "location", "to": return "输入关键词筛选位置"
            case "url": return "例如 https://example.com"
            case "title":
                let suggested = LauncherModel.suggestedTitle(for: model.draft.url)
                return suggested.isEmpty ? "输入书签标题" : suggested
            case "folder": return "输入新文件夹名称"
            case "name": return prompt.command == "rename" ? "输入新文件夹名称" : "输入文件夹名称"
            case "path", "file": return "输入路径，Tab 查看候选"
            default: return nil
            }
        }
        switch model.inputKind {
        case .search: return model.buffer == .commands ? "筛选命令名或名称" : "搜索标题或网址"
        case .command: return "输入命令，如 add / calc / set / help"
        case .calc: return "输入算式，如 (12 + 8) * 3"
        default: return nil
        }
    }

    private func layoutInput() {
        let origin = canvasOrigin
        // NSTextField 的单行文本不按控件中心垂直居中（实测比中心高约 4pt），
        // 下移 4pt 让输入文字与命令行里的提示符、占位符共用一条视觉基线。
        input.frame = NSRect(x: origin.x + inputX * scale, y: origin.y + 763 * scale,
                             width: max(160, 1400 - inputX) * scale, height: 28 * scale)
        input.font = TerminalDrawing.font(15.5 * scale)
    }

    private func synchronize() {
        accessibilityNeedsRefresh = true
        let revisionChanged = model.inputRevision != inputRevision
        if revisionChanged {
            savedSelection = nil
            inputRevision = model.inputRevision
        }
        let editor = input.currentEditor() as? NSTextView
        if input.stringValue != model.inputText, editor?.hasMarkedText() != true {
            input.stringValue = model.inputText
        }
        input.isHidden = !model.isTextInputActive
        input.setAccessibilityHelp(inputAccessibilityHelp)
        layoutInput()
        if model.visible, window?.isKeyWindow == true {
            if model.isTextInputActive {
                if revisionChanged || window?.firstResponder === self {
                    focusInput(selection: revisionChanged ? nil : savedSelection)
                }
            } else if editor != nil {
                window?.makeFirstResponder(self)
            }
        }
        if !model.isOrganizing || model.buffer != nil || model.prompt != nil { cancelDrag() }
        needsDisplay = true
    }

    func prepareForHide() {
        if let editor = input.currentEditor() as? NSTextView {
            savedSelection = editor.selectedRange()
            savedRevision = model.inputRevision
        }
        cancelDrag()
    }

    func restoreFocus() {
        synchronize()
        guard window?.isKeyWindow == true else { return }
        if model.isTextInputActive {
            focusInput(selection: savedRevision == model.inputRevision ? savedSelection : nil)
        } else { window?.makeFirstResponder(self) }
    }

    private func focusInput(selection: NSRange?) {
        guard model.isTextInputActive else { return }
        window?.makeFirstResponder(input)
        guard let editor = input.currentEditor() as? NSTextView, !editor.hasMarkedText() else { return }
        editor.insertionPointColor = TerminalDrawing.amber
        editor.drawsBackground = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.allowsUndo = true
        let length = (input.stringValue as NSString).length
        let range = selection ?? NSRange(location: length, length: 0)
        let location = min(range.location, length)
        editor.setSelectedRange(NSRange(location: location, length: min(range.length, length - location)))
        editor.scrollRangeToVisible(editor.selectedRange())
    }

    func controlTextDidChange(_ notification: Notification) {
        if model.inputKind == .calc, let editor = input.currentEditor() as? NSTextView {
            // 输入法组合中保留原文，提交后再归一化，避免打断组合。
            guard !editor.hasMarkedText() else { return }
            let raw = input.stringValue
            let filtered = TerminalCalculator.filtered(raw)
            if filtered != raw {
                let selection = editor.selectedRange()
                let rawText = raw as NSString
                let prefix = rawText.substring(to: min(selection.location, rawText.length))
                let mapped = (TerminalCalculator.filtered(prefix) as NSString).length
                input.stringValue = filtered
                editor.setSelectedRange(NSRange(location: min(mapped, (filtered as NSString).length), length: 0))
                model.updateInput(filtered)
            } else {
                model.updateInput(raw)
            }
            savedSelection = editor.selectedRange()
            savedRevision = model.inputRevision
            return
        }
        model.updateInput(input.stringValue)
        if let editor = input.currentEditor() as? NSTextView {
            savedSelection = editor.selectedRange()
            savedRevision = model.inputRevision
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText(), let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return LauncherKeyRouter.handle(event, model: model, firstResponder: textView)
    }

    override func keyDown(with event: NSEvent) {
        if !model.handleKey(event, isTextEditing: false) { super.keyDown(with: event) }
    }

    private func designPoint(_ event: NSEvent) -> NSPoint {
        let point = convert(event.locationInWindow, from: nil)
        return NSPoint(x: (point.x - canvasOrigin.x) / scale, y: (point.y - canvasOrigin.y) / scale)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard model.prompt == nil, !model.busy else { return nil }
        let point = designPoint(event)
        guard let hit = regions.last(where: { $0.rect.contains(point) }), let action = hit.action else { return nil }
        if model.buffer == nil, model.store.isLoaded,
           case let .item(index) = action, model.items.indices.contains(index) {
            model.selectItem(at: index)
            synchronize()
            let item = model.items[index]
            let menu = NSMenu()
            if item.kind == .folder {
                menu.addItem(makeMenuItem(item.expanded ? "折叠" : "展开", action: #selector(contextActivate)))
                menu.addItem(makeMenuItem("重命名", action: #selector(contextEdit)))
                menu.addItem(.separator())
                menu.addItem(makeMenuItem("删除", action: #selector(contextDelete)))
            } else {
                menu.addItem(makeMenuItem("打开", action: #selector(contextActivate)))
                menu.addItem(makeMenuItem("复制网址", action: #selector(contextCopy)))
                menu.addItem(makeMenuItem("编辑", action: #selector(contextEdit)))
                menu.addItem(makeMenuItem("移动", action: #selector(contextMove)))
                menu.addItem(.separator())
                menu.addItem(makeMenuItem("删除", action: #selector(contextDelete)))
            }
            return menu
        }
        if model.buffer == .commands, model.customScreen == .list, !model.customSaving,
           case let .custom(.row(index)) = action, model.filteredCustomCommands.indices.contains(index) {
            model.selectCustomCommand(index)
            synchronize()
            let menu = NSMenu()
            menu.addItem(makeMenuItem("运行", action: #selector(contextRunCommand)))
            menu.addItem(makeMenuItem("复制调用", action: #selector(contextCopyObject)))
            menu.addItem(makeMenuItem("编辑", action: #selector(contextEditCommand)))
            menu.addItem(makeMenuItem("创建副本", action: #selector(contextDuplicateCommand)))
            menu.addItem(.separator())
            menu.addItem(makeMenuItem("删除", action: #selector(contextDeleteCommand)))
            return menu
        }
        if model.buffer == .calc, case let .calcRow(index) = action, model.calcHistory.indices.contains(index) {
            model.selectCalcEntry(at: index)
            synchronize()
            let menu = NSMenu()
            menu.addItem(makeMenuItem("载入算式", action: #selector(contextLoadCalc)))
            menu.addItem(makeMenuItem("复制结果", action: #selector(contextCopyCalcResult)))
            menu.addItem(makeMenuItem("复制算式", action: #selector(contextCopyCalcExpression)))
            menu.addItem(.separator())
            menu.addItem(makeMenuItem("删除该条", action: #selector(contextDeleteCalc)))
            menu.addItem(makeMenuItem("清空全部", action: #selector(contextClearCalc)))
            return menu
        }
        return nil
    }

    private func makeMenuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func contextActivate() { model.activateSelection(); synchronize() }
    @objc private func contextCopy() { model.copySelection(); synchronize() }
    @objc private func contextEdit() {
        if model.items.indices.contains(model.selectedIndex), model.items[model.selectedIndex].kind == .folder {
            model.beginRename()
        } else {
            model.beginEdit()
        }
        synchronize()
    }
    @objc private func contextMove() { model.beginMove(); synchronize() }
    @objc private func contextDelete() { model.requestDeleteSelection(); synchronize() }
    @objc private func contextRunCommand() { if let command = model.selectedCustomCommand { model.executeCustomCommand(command) }; synchronize() }
    @objc private func contextCopyObject() { model.copyCurrentObject(); synchronize() }
    @objc private func contextEditCommand() { if let command = model.selectedCustomCommand { model.beginCustomEdit(command) }; synchronize() }
    @objc private func contextDuplicateCommand() { model.duplicateCurrentCommand(); synchronize() }
    @objc private func contextDeleteCommand() { model.requestCustomDelete(); synchronize() }
    @objc private func contextLoadCalc() { model.loadCalcHistorySelection(); synchronize() }
    @objc private func contextCopyCalcResult() { model.copyCalcResult(); synchronize() }
    @objc private func contextCopyCalcExpression() { model.copyCalcExpression(); synchronize() }
    @objc private func contextDeleteCalc() { model.deleteCalcHistorySelection(); synchronize() }
    @objc private func contextClearCalc() { model.clearCalc(); model.setCalcFeedback("✓ 已清空", .success); synchronize() }

    override func mouseDown(with event: NSEvent) {
        cancelDrag()
        let point = designPoint(event)
        guard let hit = regions.last(where: { $0.rect.contains(point) }), let action = hit.action else { return }
        if model.prompt != nil {
            switch action {
            case .choice, .promptField, .input, .ui: break
            case .custom where model.prompt?.command.hasPrefix("commands-") == true: break
            default: return
            }
        }
        if case let .item(index) = action,
           model.isOrganizing, model.query.isEmpty, model.items.indices.contains(index), model.items[index].kind == .bookmark {
            dragSource = model.items[index].id
            dragStart = point
        }
        perform(action, activate: event.clickCount >= 2)
    }

    func perform(_ action: Action, activate: Bool = false) {
        switch action {
        case let .item(index):
            model.selectItem(at: index)
            if activate { model.activateSelection() }
        case let .delete(index):
            model.selectItem(at: index)
            model.requestDeleteSelection()
        case let .toggle(index):
            guard model.items.indices.contains(index), model.items[index].kind == .folder else { break }
            let id = model.items[index].id
            model.selectItem(at: index)
            model.toggleExpanded(id)
        case let .choice(index):
            model.choosePromptOption(at: index, activate: activate)
        case let .promptField(field):
            model.selectBookmarkPromptField(field)
        case let .complete(command):
            model.updateInput(command + " ")
            input.stringValue = model.inputText
            focusInput(selection: nil)
        case let .draft(command):
            model.startCommand()
            model.updateInput(command + " ")
            synchronize()
        case let .command(command):
            model.runCommand(command)
        case let .calcRow(index):
            model.selectCalcEntry(at: index)
            if activate { model.loadCalcHistorySelection() }
        case let .custom(action):
            performCustomAction(action, activate: activate)
        case let .ui(action):
            performUIAction(action)
        case .input:
            if model.isTextInputActive {
                focusInput(selection: (input.currentEditor() as? NSTextView)?.selectedRange() ?? savedSelection)
            }
            else if model.buffer == .calc, model.prompt == nil { model.focusCalcInput() }
            else if model.customDirectoryFocused { model.leaveCustomDirectoryChoices() }
            else if model.prompt?.choicesFocused == true { model.prompt?.choicesFocused = false }
            else if model.prompt == nil { model.startCommand() }
        }
        synchronize()
    }

    private func performUIAction(_ action: UIAction) {
        switch action {
        case .add: model.addCurrentObject()
        case .mkdir: model.beginMkdir()
        case .edit:
            if model.items.indices.contains(model.selectedIndex), model.items[model.selectedIndex].kind == .folder {
                model.beginRename()
            } else { model.beginEdit() }
        case .move: model.beginMove()
        case .deleteSelection: model.requestDeleteSelection()
        case .copy: model.copyCurrentObject()
        case .toggleOrganizing: model.toggleOrganizing()
        case .toggleAllExpanded: model.toggleAllExpanded()
        case .openSettings: model.openSettings()
        case .openHelp: model.openBuffer(.help)
        case .activate: model.activateSelection()
        case .search: model.startSearch()
        case .startCommand: model.startCommand()
        case .escape: model.escape()
        case .submitPrompt: model.submitInput()
        case .savePrompt: model.submitPrompt()
        case .confirmDelete: model.confirmPrompt()
        case .switchField: model.switchPromptField(1)
        case .togglePromptChoices:
            guard let prompt = model.prompt, !prompt.choices.isEmpty else { break }
            model.prompt?.choicesFocused.toggle()
        case .focusCalcHistory:
            if !model.calcHistory.isEmpty { model.selectCalcEntry(at: model.calcHistoryIndex ?? 0) }
        case .loadCalcHistory: model.loadCalcHistorySelection()
        case .copyCalc: model.copyCalcResult()
        case .clearCalc:
            model.clearCalc()
            model.setCalcFeedback("✓ 已清空", .success)
        case .deleteCalcHistory: model.deleteCalcHistorySelection()
        case .submitCalc: model.submitCalc()
        case .focusSearchList:
            if !model.items.isEmpty { model.selectItem(at: model.selectedIndex) }
        case .openSearch: model.openSearch()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let source = dragSource, model.isOrganizing, model.prompt == nil else { return }
        let point = designPoint(event)
        guard dragging || hypot(point.x - dragStart.x, point.y - dragStart.y) > 5 else { return }
        dragging = true
        if point.y < rowsTop + 6 { model.scroll(rows: -1) }
        else if point.y > rowsTop + CGFloat(model.visibleRowCount) * 32 - 6 { model.scroll(rows: 1) }
        let target: DropTarget?
        let row = Int(floor((point.y - rowsTop) / 32)) + model.scrollIndex
        if point.x >= 46, point.x <= 1394, point.y >= rowsTop,
           row >= model.scrollIndex, row < model.scrollIndex + model.visibleRowCount,
           model.items.indices.contains(row), model.items[row].id != source {
            let item = model.items[row]
            let dy = point.y - rowsTop - CGFloat(row - model.scrollIndex) * 32
            let sourceIsRoot = model.document.bookmarks.first { $0.id == source }?.groupId == nil
            target = DropTarget(id: item.id, before: dy < 16,
                                merge: sourceIsRoot && item.kind == .bookmark && item.groupID == nil && dy >= 9 && dy <= 23, row: row)
        } else { target = nil }
        if target != dropTarget {
            mergeDelay?.cancel()
            mergeReady = false
            dropTarget = target
            if target?.merge == true {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.dragging, self.dropTarget == target, self.model.visible else { return }
                    self.mergeReady = true
                    self.needsDisplay = true
                }
                mergeDelay = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if dragging, let source = dragSource, let target = dropTarget {
            model.dropBookmark(sourceID: source, targetID: target.id, before: target.before, merge: target.merge && mergeReady)
        }
        cancelDrag()
    }

    private func cancelDrag() {
        mergeDelay?.cancel()
        mergeDelay = nil
        let hadDrag = dragging
        dragSource = nil
        dragging = false
        dropTarget = nil
        mergeReady = false
        if hadDrag { needsDisplay = true }
    }

    override func scrollWheel(with event: NSEvent) {
        guard model.prompt == nil else { return }
        if event.phase == .began { wheelRemainder = 0 }
        wheelRemainder += event.hasPreciseScrollingDeltas ? -event.scrollingDeltaY / (32 * scale) : -event.scrollingDeltaY
        let rows = Int(wheelRemainder)
        if rows != 0 { wheelRemainder -= CGFloat(rows); model.scroll(rows: rows) }
    }

    override func draw(_ dirtyRect: NSRect) {
        TerminalDrawing.rect(bounds, TerminalDrawing.paper)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: canvasOrigin.x, y: canvasOrigin.y)
        context.scaleBy(x: scale, y: scale)
        context.clip(to: CGRect(x: 0, y: 0, width: 1440, height: 900))
        regions.removeAll(keepingCapacity: true)
        let foreignPrompt = model.buffer == .commands && model.prompt.map { !$0.command.hasPrefix("commands-") } == true
        let showsOutput = (model.buffer != .commands || foreignPrompt) && (model.buffer == nil || model.prompt != nil || model.inputKind == .command
            || (model.inputKind != nil && model.buffer != .calc))
        if let buffer = model.buffer {
            context.saveGState()
            if showsOutput { context.clip(to: CGRect(x: 40, y: 24, width: 1360, height: 624)) }
            drawBuffer(buffer)
            context.restoreGState()
            if showsOutput { regions.removeAll { $0.rect.maxY > 648 } }
        } else { drawList() }
        if showsOutput { drawOutput() }
        if model.inputKind == .command { drawCommandDiscovery() }
        drawChrome()
        context.restoreGState()
        refreshAccessibilityAndTooltips()
    }

    func hit(_ rect: NSRect, _ label: String, _ action: Action? = nil, selected: Bool = false) {
        regions.append(Region(rect: rect, label: label, action: action, selected: selected))
    }

    private func drawList() {
        typealias D = TerminalDrawing
        if !model.store.isLoaded {
            if model.store.isBusy {
                D.text("正在载入…", 720, 392, size: 15, color: D.teal, align: .center)
            } else if let issue = model.store.issue {
                D.icon("warn", x: 702, y: 324, size: 36, color: D.red)
                D.text("无法载入数据，原文件已保留", 720, 392, size: 15, color: D.red, bold: true, align: .center)
                D.text(issue, 720, 420, size: 12, color: D.muted, maxWidth: 1120, align: .center)
                D.text(":retry 重试", 680, 458, size: 12, color: D.teal, align: .right)
                D.text(":cd 更换目录", 760, 458, size: 12, color: D.teal)
                hit(NSRect(x: 160, y: 404, width: 1120, height: 30), issue)
                hit(NSRect(x: 540, y: 442, width: 160, height: 32), "重试载入数据", .command("retry"))
                hit(NSRect(x: 740, y: 442, width: 220, height: 32), "更换数据目录", .command("cd"))
            }
            return
        }
        let start = max(0, min(model.scrollIndex, model.items.count))
        let end = min(model.items.count, start + model.visibleRowCount)
        if start < end {
            for index in start..<end { drawItem(model.items[index], index: index, y: rowsTop + CGFloat(index - start) * 32) }
        }
        if model.items.isEmpty {
            if !model.query.isEmpty {
                D.icon("search", x: 706, y: 324, size: 28, color: D.muted)
                D.text("没有匹配的书签", 720, 388, size: 16, color: D.ink2, bold: true, align: .center)
            } else {
                D.text("∅", 720, 352, size: 38, color: D.muted.withAlphaComponent(0.42), align: .center)
                D.text("暂无书签", 720, 402, size: 15, color: D.ink2, bold: true, align: .center)
            }
        }
        if model.items.count > model.visibleRowCount {
            let trackHeight = CGFloat(model.visibleRowCount) * 32
            D.rect(NSRect(x: 1404, y: rowsTop, width: 2, height: trackHeight), D.line)
            let thumbHeight = max(20, trackHeight * CGFloat(model.visibleRowCount) / CGFloat(model.items.count))
            let thumbY = rowsTop + (trackHeight - thumbHeight) * CGFloat(start) / CGFloat(max(1, model.items.count - model.visibleRowCount))
            D.rect(NSRect(x: 1404, y: thumbY, width: 2, height: thumbHeight), D.muted)
        }
        drawDropTarget()
    }

    private func drawItem(_ item: TerminalItem, index: Int, y: CGFloat) {
        typealias D = TerminalDrawing
        let selected = index == model.selectedIndex
        let foreground = selected ? D.paper : D.ink
        let meta = selected ? D.mint : D.muted
        let cy = y + 16
        let indent: CGFloat = item.depth > 0 ? 32 : 0
        if selected {
            D.rect(NSRect(x: 46, y: y + 1, width: 1348, height: 30), D.ink)
            D.rect(NSRect(x: 46, y: y + 1, width: 3, height: 30), D.yellow)
        }
        hit(NSRect(x: 46, y: y, width: 1348, height: 32), "\(item.title)\(item.url.map { "，" + $0 } ?? "，" + item.detail)", .item(index), selected: selected)
        if model.isOrganizing, item.kind == .bookmark {
            D.text("[×]", 54, cy, size: 12, color: selected ? D.lemon : D.red, bold: true)
            hit(NSRect(x: 46, y: y, width: 40, height: 32), "删除 \(item.title)", .delete(index))
        }
        if item.kind == .folder {
            D.icon(item.expanded ? "chevron-down" : "chevron", x: 74, y: cy - 8, color: selected ? D.yellow : D.muted)
            hit(NSRect(x: 70, y: y, width: 26, height: 32), (item.expanded ? "折叠 " : "展开 ") + item.title, .toggle(index))
            D.icon("folder", x: 98, y: cy - 10, size: 20, color: selected ? D.mint : D.purple)
            D.text(item.title, 134, cy, color: selected ? D.paper : D.purple, bold: true, maxWidth: 1050)
            D.text(item.detail + (model.isOrganizing ? " · 固定" : ""), 1390, cy, size: 11.5, color: meta, maxWidth: 200, align: .right)
        } else {
            if item.depth > 0 {
                D.rect(NSRect(x: 106, y: y, width: 1, height: 32), D.line)
                D.rect(NSRect(x: 106, y: cy, width: 18, height: 1), D.line)
            }
            D.tile(item, x: 98 + indent, y: cy)
            let hostWidth = min(420, D.width(item.detail, size: 12))
            let tag = model.query.isEmpty ? nil : item.groupName
            let tagWidth = tag.map { min(220, D.width($0, size: 10)) + 10 } ?? 0
            let titleWidth = max(90, 1390 - hostWidth - 18 - 134 - indent - (tag == nil ? 0 : tagWidth + 12))
            D.text(item.title, 134 + indent, cy, color: foreground, maxWidth: titleWidth)
            if let tag {
                let tagX = 144 + indent + min(titleWidth, D.width(item.title, size: 14))
                D.rect(NSRect(x: tagX, y: cy - 9, width: tagWidth, height: 18), D.line)
                D.text(tag, tagX + 5, cy, size: 10, color: D.purple, maxWidth: tagWidth - 10)
            }
            D.text(item.detail, 1390, cy, size: 12, color: meta, maxWidth: hostWidth, align: .right)
        }
    }

    private func drawDropTarget() {
        guard dragging, let target = dropTarget, let row = target.row, model.items.indices.contains(row) else { return }
        typealias D = TerminalDrawing
        let y = rowsTop + CGFloat(row - model.scrollIndex) * 32
        let item = model.items[row]
        let label = item.kind == .folder ? "移入“\(item.title)”" : target.merge && mergeReady ? "＋ 新建文件夹" : target.merge ? "停留新建文件夹" : "移至此处"
        let width = min(500, D.width(label, size: 11) + 16)
        D.green.setStroke()
        NSBezierPath(rect: NSRect(x: 46, y: y + 1, width: 1348, height: 30)).stroke()
        D.rule(46, target.before ? y : y + 31, 1348, color: D.green, height: 2)
        D.rect(NSRect(x: 1394 - width, y: y - 20, width: width, height: 18), D.mint)
        D.text(label, 1402 - width, y - 11, size: 11, color: D.pine, bold: true, maxWidth: width - 16)
    }

    private func drawOutput() {
        typealias D = TerminalDrawing
        if let prompt = model.prompt {
            if ["add", "edit"].contains(prompt.command) {
                drawBookmarkPromptPanel(prompt)
                return
            }
            if prompt.command == "move" {
                drawMovePromptPanel(prompt)
                return
            }
            if ["cd", "backup", "restore"].contains(prompt.command) {
                drawFilePromptPanel(prompt)
                return
            }
            let context: String? = prompt.command == "delete" ? "删除“\(model.draft.title)”？" : prompt.context
            guard prompt.error != nil || context != nil else { return }
            D.rect(NSRect(x: 40, y: 664, width: 1360, height: 72), D.surface)
            D.rule(40, 664, 1360)
            if let error = prompt.error {
                D.text(error, 54, context == nil ? 700 : 686, size: 12.5, color: D.red, maxWidth: 1320)
                hit(NSRect(x: 54, y: context == nil ? 688 : 674, width: 1320, height: 24), error)
            }
            if let context {
                D.text(context, 54, prompt.error == nil ? 700 : 714, size: 12.5, color: prompt.command == "delete" ? D.red : D.muted, maxWidth: 1320)
                hit(NSRect(x: 54, y: prompt.error == nil ? 688 : 702, width: 1320, height: 24), context)
            }
            return
        }
        D.rect(NSRect(x: 40, y: 664, width: 1360, height: 72), D.paper)
        D.rule(40, 664, 1360)
        if let issue = model.store.issue, model.inputKind == nil {
            D.text("ERROR · 原数据已保留", 40, 679, size: 10.5, color: D.red)
            D.text(issue, 40, 700, size: 12.5, color: D.red, maxWidth: 1360)
            hit(NSRect(x: 40, y: 688, width: 1360, height: 24), issue)
            return
        }
        if model.isOrganizing {
            D.text("ORGANIZE", 40, 678, size: 11, color: D.green, bold: true)
            D.text("文件夹置顶且固定，书签仅在同组内排序", 40, 699, size: 13, color: D.ink2)
            D.text("可拖动排序、移入文件夹，或在根书签上停留新建文件夹", 40, 718, size: 12, color: D.muted)
            return
        }
        D.text("OUTPUT", 40, 679, size: 10.5, color: D.muted)
        D.text("查看日志", 1400, 679, size: 10.5, color: D.muted, align: .right)
        hit(NSRect(x: 1280, y: 666, width: 120, height: 22), "查看全部日志", .command("log"))
        if model.logs.isEmpty {
            D.text("就绪", 40, 704, size: 12, color: D.muted)
        } else {
            for (index, entry) in model.logs.suffix(3).enumerated() {
                let y = 698 + CGFloat(index) * 16
                D.text(entry.time, 40, y, size: 11.5, color: D.muted, maxWidth: 64)
                D.text(entry.text, 106, y, size: 12.5, color: D.level(entry.level), maxWidth: 1294)
                hit(NSRect(x: 106, y: y - 8, width: 1294, height: 16), entry.text)
            }
        }
    }

    private func drawBookmarkPromptPanel(_ prompt: TerminalPrompt) {
        typealias D = TerminalDrawing
        let summaryRows = model.bookmarkSummaryRows
        let showsChoices = prompt.field == "location"
        let visibleChoices = showsChoices ? min(6, max(1, prompt.choices.count)) : 0
        let choiceBlockHeight: CGFloat = showsChoices ? 28 + CGFloat(visibleChoices) * 24 + 8 : 0
        let panelHeight: CGFloat = 34 + CGFloat(summaryRows.count) * 24 + choiceBlockHeight + 10
        let top = 736 - panelHeight

        D.rect(NSRect(x: 40, y: top, width: 1360, height: panelHeight), D.surface)
        D.rect(NSRect(x: 40, y: top, width: 3, height: panelHeight), D.yellow)
        D.rule(40, top, 1360)

        let headerY = top + 18
        let headerTitle = prompt.command == "add" ? "ADD · 新建书签" : "EDIT · 编辑书签"
        D.text(headerTitle, 56, headerY, size: 10.5, color: D.muted, bold: true)

        if let error = prompt.error {
            D.text(error, 1384, headerY, size: 11.5, color: D.red, bold: true, maxWidth: 1040, align: .right)
            hit(NSRect(x: 340, y: top + 6, width: 1044, height: 22), error)
        } else if let duplicate = model.duplicateBookmarkForDraft {
            let notice = "已有相同网址 · 位于\(duplicate.locationName == "根目录" ? "根目录" : "“\(duplicate.locationName)”")"
            D.text(notice, 1384, headerY, size: 11.5, color: D.amber, maxWidth: 1040, align: .right)
            hit(NSRect(x: 340, y: top + 6, width: 1044, height: 22), notice)
        } else if prompt.command == "add", model.draft.prefilledFromClipboard, prompt.field == "url" {
            D.text("已自动填入剪贴板网址", 1384, headerY, size: 11, color: D.teal, maxWidth: 600, align: .right)
        }

        var y = top + 46
        for (index, row) in summaryRows.enumerated() {
            if row.active {
                D.rect(NSRect(x: 46, y: y - 11, width: 1348, height: 22), D.ink)
                D.rect(NSRect(x: 46, y: y - 11, width: 3, height: 22), D.yellow)
            }
            D.text(String(format: "%02d", index + 1), 56, y, size: 10.5, color: row.active ? D.yellow : D.muted)
            D.text(row.label, 88, y, size: 11.5, color: row.active ? D.mint : D.muted, maxWidth: 96)
            let displayValue = row.value.isEmpty ? (row.placeholder ?? "") : row.value
            let valueColor = row.value.isEmpty ? (row.active ? D.paper.withAlphaComponent(0.6) : D.muted) : (row.active ? D.paper : D.ink)
            D.text(displayValue, 192, y, size: 12.5, color: valueColor, maxWidth: 1188)
            hit(NSRect(x: 46, y: y - 11, width: 1348, height: 22), "\(row.label)：\(displayValue)", .promptField(row.field), selected: row.active)
            y += 24
        }

        if showsChoices {
            let dividerY = y - 4
            D.rule(56, dividerY, 1328)
            D.text("LOCATIONS · \(prompt.choices.count) 项", 56, dividerY + 16, size: 10, color: D.muted)
            drawChoiceRows(prompt: prompt, startY: dividerY + 38, maxVisible: 6, highlightSelected: true)
        }
    }

    private func drawMovePromptPanel(_ prompt: TerminalPrompt) {
        typealias D = TerminalDrawing
        let showsChoices = prompt.field == "to"
        let visibleChoices = showsChoices ? min(6, max(1, prompt.choices.count)) : 0
        let panelHeight: CGFloat = showsChoices ? 40 + CGFloat(visibleChoices) * 24 + 10 : 72
        let top = 736 - panelHeight

        D.rect(NSRect(x: 40, y: top, width: 1360, height: panelHeight), D.surface)
        D.rect(NSRect(x: 40, y: top, width: 3, height: panelHeight), D.yellow)
        D.rule(40, top, 1360)

        let headerY = top + 18
        D.text("MOVE · 移动“\(model.draft.title)”", 56, headerY, size: 11, color: D.muted, bold: true, maxWidth: 720)
        if let error = prompt.error {
            D.text(error, 1384, headerY, size: 11.5, color: D.red, bold: true, maxWidth: 640, align: .right)
            hit(NSRect(x: 740, y: top + 6, width: 644, height: 22), error)
        }
        if showsChoices {
            drawChoiceRows(prompt: prompt, startY: top + 46, maxVisible: 6, highlightSelected: true)
        } else {
            D.text("将新建文件夹并移入该书签", 56, top + 46, size: 12, color: D.muted, maxWidth: 1320)
        }
    }

    private func drawFilePromptPanel(_ prompt: TerminalPrompt) {
        typealias D = TerminalDrawing
        let warning: String? = prompt.command == "restore" ? "将替换全部书签与文件夹，不合并" : nil
        let visibleChoices = min(6, prompt.choices.count)
        let hasChoices = visibleChoices > 0
        let panelHeight: CGFloat = hasChoices ? 40 + CGFloat(visibleChoices) * 24 + 10 : 72
        let top = 736 - panelHeight

        guard hasChoices || prompt.error != nil || warning != nil else { return }
        D.rect(NSRect(x: 40, y: top, width: 1360, height: panelHeight), D.surface)
        D.rect(NSRect(x: 40, y: top, width: 3, height: panelHeight), D.yellow)
        D.rule(40, top, 1360)

        let headerY = hasChoices ? top + 18 : top + 36
        if let error = prompt.error {
            D.text(error, 56, warning == nil || hasChoices ? headerY : top + 24, size: 12, color: D.red, bold: true, maxWidth: 1320)
            hit(NSRect(x: 56, y: top + 8, width: 1320, height: 24), error)
            if let warning, !hasChoices {
                D.text(warning, 56, top + 50, size: 12, color: D.muted, maxWidth: 1320)
            }
        } else if let warning {
            D.text(warning, 56, headerY, size: 12, color: D.amber, bold: true, maxWidth: 960)
            hit(NSRect(x: 56, y: headerY - 11, width: 960, height: 22), warning)
        } else if hasChoices {
            D.text("PATHS · \(prompt.choices.count) 项", 56, headerY, size: 10.5, color: D.muted)
        }

        if hasChoices {
            if prompt.choices.count > 6 {
                let start = max(0, min(prompt.selectedChoice - 5, prompt.choices.count - 6))
                D.text("\(start + 1)–\(min(start + 6, prompt.choices.count)) / \(prompt.choices.count)",
                       1384, top + 18, size: 10, color: D.muted, align: .right)
            }
            drawChoiceRows(prompt: prompt, startY: top + 46, maxVisible: 6, highlightSelected: prompt.choicesFocused)
        }
    }

    private func drawChoiceRows(prompt: TerminalPrompt, startY: CGFloat, maxVisible: Int, highlightSelected: Bool) {
        typealias D = TerminalDrawing
        if prompt.choices.isEmpty {
            D.text("没有匹配的位置", 56, startY, size: 12, color: D.muted)
            return
        }
        let start = max(0, min(prompt.selectedChoice - (maxVisible - 1), prompt.choices.count - maxVisible))
        let end = min(prompt.choices.count, start + maxVisible)
        for index in start..<end {
            let choice = prompt.choices[index]
            let y = startY + CGFloat(index - start) * 24
            let selected = highlightSelected && index == prompt.selectedChoice
            if selected {
                D.rect(NSRect(x: 46, y: y - 11, width: 1348, height: 22), D.ink)
                D.rect(NSRect(x: 46, y: y - 11, width: 3, height: 22), D.yellow)
            }
            D.text(String(format: "%02d", index + 1), 56, y, size: 10.5, color: selected ? D.yellow : D.muted)
            D.text(choice.label, 88, y, size: 12.5, color: selected ? D.paper : D.ink, maxWidth: 960)
            if !choice.detail.isEmpty {
                D.text(choice.detail, 1384, y, size: 11, color: selected ? D.mint : D.muted, maxWidth: 320, align: .right)
            }
            hit(NSRect(x: 46, y: y - 11, width: 1348, height: 22),
                choice.detail.isEmpty ? choice.label : "\(choice.label)（\(choice.detail)）",
                .choice(index), selected: selected)
        }
    }

    private func drawChrome() {
        typealias D = TerminalDrawing
        let page: (name: String, background: NSColor, accent: NSColor)?
        switch model.buffer {
        case nil: page = ("主界面", D.bookmarkInput, D.green)
        case .commands: page = ("自定义命令", D.commandInput, D.blue)
        case .calc: page = ("计算器", D.calculatorInput, D.amber)
        default: page = nil
        }
        if let page {
            D.rect(NSRect(x: 0, y: 752, width: 1440, height: 44), page.background)
            D.rect(NSRect(x: 0, y: 752, width: 5, height: 44), page.accent)
        } else if model.prompt != nil {
            D.rect(NSRect(x: 0, y: 752, width: 1440, height: 44), D.surface)
        }
        if model.prompt != nil {
            D.rect(NSRect(x: 0, y: 752, width: 3, height: 44), D.yellow)
        }
        D.rule(0, 752, 1440)
        let isCalc = model.buffer == .calc && model.inputKind == .calc
        let symbol = isCalc ? "=" : model.inputKind == .search ? "/" : model.inputKind != nil || model.prompt != nil ? ":" : "›"
        let symbolColor = isCalc ? D.amber : model.inputKind == .search ? (page?.accent ?? D.teal)
            : model.inputKind != nil || model.prompt != nil ? D.amber : D.green
        D.text(symbol, 40, 773, size: 17, color: symbolColor, bold: true)
        if let prompt = model.prompt { D.text(prompt.label, 58, 773, size: 13, color: D.muted, maxWidth: inputX - 70) }
        else if isCalc { D.text(Self.calcLabel, 58, 773, size: 13, color: D.muted, maxWidth: inputX - 70) }
        if !model.isTextInputActive {
            if model.prompt != nil { D.text(model.inputText, inputX, 773, size: 15.5, maxWidth: 1400 - inputX) }
            else {
                let placeholder: String
                if model.customStopConfirmation { placeholder = "停止确认 · 默认取消" }
                else if model.buffer == .calc, model.calcHistoryFocused { placeholder = "算式草稿：" + model.calcExpression }
                else { placeholder = "输入命令" }
                D.text(placeholder, inputX + 2, 773, color: D.muted, maxWidth: 1400 - inputX)
            }
        } else if let placeholder = activeInputPlaceholder {
            D.text(placeholder, inputX + 2, 773, size: 14, color: D.muted.withAlphaComponent(0.75), maxWidth: 1400 - inputX)
        }
        hit(NSRect(x: 40, y: 752, width: 1360, height: 44), "命令行输入", .input)
        D.rect(NSRect(x: 0, y: 796, width: 1440, height: 36), D.forest)
        let statusLabel = statusBarTitle()
        D.text(statusLabel, 40, 815.5, size: 12.5, color: D.yellow, bold: true, maxWidth: 800)
        if model.buffer == nil, model.prompt == nil {
            let status: String?
            if !model.query.isEmpty {
                status = "“\(model.query)” · \(model.items.count) 条"
            } else if !model.expandedGroupIDs.isEmpty {
                status = "已展开 \(model.expandedGroupIDs.count) 个文件夹"
            } else {
                status = nil
            }
            if let status {
                let x = 72 + D.width(statusLabel, size: 12.5, bold: true)
                D.text("· \(status)", x, 815.5, size: 12.5,
                       color: D.paper.withAlphaComponent(0.82), maxWidth: max(0, 740 - x))
            }
        }
        drawShortcutHints()
    }

    private func statusBarTitle() -> String {
        switch model.buffer {
        case nil:
            return "主界面 · " + model.modeLabel
        case .calc:
            if model.inputKind == .command { return "计算器 · COMMAND" }
            if model.calcHistoryFocused { return "计算器 · HISTORY" }
            if model.prompt != nil { return "计算器 · PROMPT" }
            return "计算器"
        case .commands:
            if model.customStopConfirmation { return "自定义命令 · CONFIRM:STOP" }
            if model.inputKind == .command { return "自定义命令 · COMMAND" }
            if model.inputKind == .search { return "自定义命令 · SEARCH" }
            switch model.customScreen {
            case .list: return "自定义命令"
            case .edit: return "自定义命令 · EDIT"
            case .delete: return "自定义命令 · CONFIRM"
            case .execution: return "自定义命令 · EXEC"
            }
        default:
            return model.modeLabel
        }
    }

    private func drawShortcutBar(_ hints: [ShortcutHint]) {
        typealias D = TerminalDrawing
        guard !hints.isEmpty else { return }
        let fontSize: CGFloat = 11
        let innerGap: CGFloat = 5
        let itemGap: CGFloat = 16
        let minX: CGFloat = 40
        let maxX: CGFloat = 1400

        struct MeasuredHint {
            let hint: ShortcutHint
            let keyWidth: CGFloat
            let labelWidth: CGFloat
            let totalWidth: CGFloat
        }
        let measured = hints.map { hint in
            let keyWidth = max(22, D.width(hint.key, size: fontSize) + 10)
            let labelWidth = D.width(hint.label, size: fontSize)
            return MeasuredHint(hint: hint, keyWidth: keyWidth, labelWidth: labelWidth,
                                totalWidth: keyWidth + innerGap + labelWidth)
        }
        var rows: [[MeasuredHint]] = [[]]
        var currentWidth: CGFloat = 0
        for item in measured {
            let added = (rows[rows.count - 1].isEmpty ? 0 : itemGap) + item.totalWidth
            if !rows[rows.count - 1].isEmpty, currentWidth + added > maxX - minX, rows.count < 2 {
                rows.append([item])
                currentWidth = item.totalWidth
            } else {
                rows[rows.count - 1].append(item)
                currentWidth += added
            }
        }
        let rowCenters: [CGFloat] = rows.count == 1 ? [864] : [850, 878]
        for (rowIndex, row) in rows.enumerated() {
            let y = rowCenters[rowIndex]
            var x = minX
            for item in row {
                let width = D.key(item.hint.key, x: x, y: y, size: fontSize)
                D.text(item.hint.label, x + width + innerGap, y + 0.5, size: fontSize, color: D.muted)
                hit(NSRect(x: x, y: y - 11, width: width + innerGap + item.labelWidth, height: 22),
                    "\(item.hint.key) \(item.hint.label)", item.hint.action)
                x += width + innerGap + item.labelWidth + itemGap
            }
        }
    }

    func currentShortcutHints() -> [ShortcutHint] {
        var hints: [ShortcutHint] = []
        func key(_ shortcut: String, _ label: String, _ action: Action? = nil) {
            hints.append(ShortcutHint(key: shortcut, label: label, action: action))
        }

        if model.busy || model.customSaving { return [] }
        let hasForeignPrompt = model.prompt.map { !$0.command.hasPrefix("commands-") } ?? false
        if model.buffer == .commands, model.inputKind != .command, !hasForeignPrompt {
            return customShortcutHints()
        }
        if let prompt = model.prompt {
            if prompt.command == "hotkey" {
                key("组合键", "录入")
                key("Esc", "取消", .ui(.escape))
            } else if prompt.command == "delete" {
                key("y", "删除", .ui(.confirmDelete))
                key("Esc", "取消", .ui(.escape))
            } else if prompt.choicesFocused {
                key("↑↓", "选择")
                key("Enter", "采纳", .ui(.submitPrompt))
                key("Esc", "返回输入", .ui(.escape))
            } else if prompt.command == "add" {
                let choosingNew = prompt.field == "location"
                    && prompt.choices.indices.contains(prompt.selectedChoice)
                    && prompt.choices[prompt.selectedChoice].id == "__new__"
                let hasFilter = prompt.field == "location" && !model.inputText.isEmpty
                if prompt.field == "location" { key("↑↓", "选择") }
                key("Tab", "切字段", .ui(.switchField))
                switch prompt.field {
                case "url", "title":
                    key("Enter", "下一步", .ui(.submitPrompt))
                    key("⌘Enter", "保存", .ui(.savePrompt))
                case "location":
                    key("Enter", choosingNew ? "命名" : "保存", .ui(.submitPrompt))
                default:
                    key("Enter", "保存", .ui(.submitPrompt))
                }
                key("Esc", hasFilter ? "清空筛选" : "放弃修改", .ui(.escape))
            } else if prompt.command == "edit" {
                let choosingNew = prompt.field == "location"
                    && prompt.choices.indices.contains(prompt.selectedChoice)
                    && prompt.choices[prompt.selectedChoice].id == "__new__"
                let hasFilter = prompt.field == "location" && !model.inputText.isEmpty
                if prompt.field == "location" { key("↑↓", "选择") }
                key("Tab", "切字段", .ui(.switchField))
                key("Enter", choosingNew ? "命名" : "保存", .ui(.submitPrompt))
                key("Esc", hasFilter ? "清空筛选" : "放弃修改", .ui(.escape))
            } else if prompt.command == "move" {
                let choosingNew = prompt.field == "to"
                    && prompt.choices.indices.contains(prompt.selectedChoice)
                    && prompt.choices[prompt.selectedChoice].id == "__new__"
                let hasFilter = prompt.field == "to" && !model.inputText.isEmpty
                if prompt.field == "to" { key("↑↓", "选择") }
                else { key("⇧Tab", "返回位置", .ui(.switchField)) }
                key("Enter", choosingNew ? "命名" : "移动", .ui(.submitPrompt))
                key("Esc", hasFilter ? "清空筛选" : "取消", .ui(.escape))
            } else {
                if !prompt.choices.isEmpty { key("Tab", "候选", .ui(.togglePromptChoices)) }
                let action: String
                switch prompt.command {
                case "backup": action = "导出"
                case "restore": action = "恢复并替换"
                case "cd": action = "切换目录"
                case "mkdir": action = "创建"
                default: action = "保存"
                }
                key("Enter", action, .ui(.submitPrompt))
                key("Esc", ["rename", "mkdir"].contains(prompt.command) ? "放弃修改" : "取消", .ui(.escape))
            }
            return hints
        }
        if model.inputKind == .command {
            if !model.commandCandidates.isEmpty { key("↑↓", "候选"); key("Tab", "补全") }
            key("⌥↑↓", "历史")
            key("Enter", "执行", .ui(.submitPrompt))
            key("Esc", "取消", .ui(.escape))
            return hints
        }
        if model.inputKind == .search {
            if !model.items.isEmpty {
                key("↑↓", "选择")
                key("Tab", "进列表", .ui(.focusSearchList))
            }
            let enterAction: Action = model.searchAction == .finish ? .ui(.escape)
                : model.searchAction == .openSelection ? .ui(.activate) : .ui(.openSearch)
            key("Enter", model.searchAction.title, enterAction)
            key("Esc", "清空", .ui(.escape))
            return hints
        }
        if let buffer = model.buffer {
            switch buffer {
            case .calc:
                if model.calcHistoryFocused {
                    key("↑↓", "选择")
                    key("Enter", "载入", .ui(.loadCalcHistory))
                    key("⌘C", "复制", .ui(.copyCalc))
                    key("⇧D", "删除", .ui(.deleteCalcHistory))
                    key("⌘⌫", "清空", .ui(.clearCalc))
                    key(":", "命令", .ui(.startCommand))
                    key("Esc", "返回草稿", .ui(.escape))
                } else {
                    key("Enter", "计算", .ui(.submitCalc))
                    if !model.calcHistory.isEmpty { key("Tab", "历史", .ui(.focusCalcHistory)) }
                    key("⌘C", "复制", .ui(.copyCalc))
                    if !model.calcExpression.isEmpty || !model.calcHistory.isEmpty {
                        key("⌘⌫", "清空", .ui(.clearCalc))
                    }
                    key(":", "命令", .ui(.startCommand))
                    key("⌘,", "设置", .ui(.openSettings))
                    key("Esc", "返回", .ui(.escape))
                }
            case .settings:
                key("↑↓", "滚动")
                key("/", "搜索", .ui(.search))
                key(":", "命令", .ui(.startCommand))
                key("?", "帮助", .ui(.openHelp))
                key("Esc", "返回", .ui(.escape))
            case .commands: break
            case .help:
                key("↑↓", "滚动")
                key("/", "搜索", .ui(.search))
                key(":", "命令", .ui(.startCommand))
                key("⌘,", "设置", .ui(.openSettings))
                key("Esc", "返回", .ui(.escape))
            case .log, .job:
                key("↑↓", "滚动")
                key("/", "搜索", .ui(.search))
                key(":", "命令", .ui(.startCommand))
                key("⌘,", "设置", .ui(.openSettings))
                key("?", "帮助", .ui(.openHelp))
                key("Esc", "返回", .ui(.escape))
            }
            return hints
        }
        if model.store.issue != nil {
            if model.store.isLoaded {
                key(":retry", "重试", .command("retry"))
                key(":cd", "更换目录", .command("cd"))
            }
            key("Esc", "收起", .ui(.escape))
            return hints
        }
        let selected = model.items.indices.contains(model.selectedIndex) ? model.items[model.selectedIndex] : nil
        let searching = !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasFolders = !model.document.groups.isEmpty
        if model.isOrganizing {
            if let selected {
                key("↑↓", "选择")
                if selected.kind == .folder {
                    key("Enter", selected.expanded ? "折叠" : "展开", .ui(.activate))
                    key("e", "重命名", .ui(.edit))
                } else {
                    key("⇧↑↓", "排序")
                    key("m", "移动", .ui(.move))
                    key("e", "编辑", .ui(.edit))
                    key("⌘C", "复制", .ui(.copy))
                }
                key("⇧D", "删除", .ui(.deleteSelection))
            }
            key("Esc", "完成", .ui(.escape))
            return hints
        }
        if let selected {
            key("↑↓", "选择")
            if selected.kind == .folder {
                key("Enter", selected.expanded ? "折叠" : "展开", .ui(.activate))
                if !searching {
                    key("a", "添加", .ui(.add))
                    key("n", "新建文件夹", .ui(.mkdir))
                }
                key("e", "重命名", .ui(.edit))
                key("⇧D", "删除", .ui(.deleteSelection))
            } else {
                key("Enter", "打开", .ui(.activate))
                if !searching {
                    key("a", "添加", .ui(.add))
                    key("n", "新建文件夹", .ui(.mkdir))
                }
                key("e", "编辑", .ui(.edit))
                key("m", "移动", .ui(.move))
                key("⇧D", "删除", .ui(.deleteSelection))
                key("⌘C", "复制", .ui(.copy))
            }
            if !searching {
                key("o", "整理", .ui(.toggleOrganizing))
                if hasFolders {
                    let allOpen = Set(model.document.groups.map(\.id)).isSubset(of: model.expandedGroupIDs)
                    key("z", allOpen ? "全折叠" : "全展开", .ui(.toggleAllExpanded))
                }
            }
        } else if searching {
            key("Enter", model.searchAction.title, .ui(.openSearch))
        } else {
            key("a", "添加书签", .ui(.add))
            key("n", "新建文件夹", .ui(.mkdir))
        }
        key("/", searching ? "继续搜索" : "搜索", .ui(.search))
        key(":", "命令", .ui(.startCommand))
        if !searching {
            key(",", "设置", .ui(.openSettings))
            key("?", "帮助", .ui(.openHelp))
        }
        key("Esc", searching ? "清空" : "收起", .ui(.escape))
        return hints
    }

    private func drawShortcutHints() {
        typealias D = TerminalDrawing
        if model.busy {
            D.text("正在处理…", 40, 864, size: 11.5, color: D.muted)
            return
        }
        if model.customSaving {
            D.text("正在保存…", 40, 864, size: 11.5, color: D.muted)
            return
        }
        drawShortcutBar(currentShortcutHints())
    }

    private func refreshAccessibilityAndTooltips() {
        guard accessibilityNeedsRefresh else { return }
        accessibilityNeedsRefresh = false
        removeAllToolTips()
        tooltipText.removeAll(keepingCapacity: true)
        accessibilityRows.removeAll(keepingCapacity: true)
        guard let window else { return }
        for region in regions {
            let rect = NSRect(x: canvasOrigin.x + region.rect.minX * scale, y: canvasOrigin.y + region.rect.minY * scale,
                              width: region.rect.width * scale, height: region.rect.height * scale)
            let tag = addToolTip(rect, owner: self, userData: nil)
            tooltipText[tag] = region.label
            let element = TerminalAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(region.action == nil ? .staticText : .button)
            element.setAccessibilityLabel(region.label)
            element.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
            if region.selected { element.setAccessibilityValue("已选择") }
            if let action = region.action {
                element.press = { [weak self] in
                    guard let self else { return false }
                    if self.model.prompt != nil {
                        switch action {
                        case .choice, .promptField, .input, .ui: break
                        case .custom where self.model.prompt?.command.hasPrefix("commands-") == true: break
                        default: return false
                        }
                    }
                    self.perform(action, activate: true)
                    return true
                }
            }
            accessibilityRows.append(element)
        }
        var children: [Any] = accessibilityRows
        if !input.isHidden { children.append(input) }
        setAccessibilityChildren(children)
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                       userData data: UnsafeMutableRawPointer?) -> String {
        tooltipText[tag] ?? ""
    }
}

@MainActor
private final class TerminalAccessibilityElement: NSAccessibilityElement {
    var press: (() -> Bool)?
    override func accessibilityPerformPress() -> Bool { press?() ?? false }
}
