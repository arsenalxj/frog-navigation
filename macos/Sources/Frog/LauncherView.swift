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

    enum Action {
        case item(Int), delete(Int), toggle(Int), choice(Int), complete(String), draft(String),
             command(String), calcRow(Int), input
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

    static let calcLabel = "calc › 算式"

    private var inputX: CGFloat {
        if let prompt = model.prompt { return min(480, 70 + TerminalDrawing.width(prompt.label, size: 13)) }
        if model.buffer == .calc, model.inputKind == .calc {
            return 70 + TerminalDrawing.width(Self.calcLabel, size: 13)
        }
        return 58
    }

    private var commandHint: String {
        if let prompt = model.prompt { return prompt.error ?? prompt.hint }
        switch model.inputKind {
        case .search: return "Enter 打开 · Esc 清空"
        case .command: return "Tab 补全 · ↑↓ 历史 · Esc 取消"
        case .calc: return model.calcFeedback ?? "Enter 计算 · ↑↓ 历史 · c 复制 · Esc 关闭"
        default: return ""
        }
    }

    private var hintWidth: CGFloat { min(510, TerminalDrawing.width(commandHint, size: 12)) }

    private func layoutInput() {
        let origin = canvasOrigin
        // NSTextField 的单行文本不按控件中心垂直居中（实测比中心高约 4pt），
        // 下移 4pt 让输入文字与命令行里的提示符、占位符共用一条视觉基线。
        input.frame = NSRect(x: origin.x + inputX * scale, y: origin.y + 763 * scale,
                             width: max(160, 1400 - hintWidth - 24 - inputX) * scale, height: 28 * scale)
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
        input.setAccessibilityHelp(model.prompt?.hint ?? commandHint)
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
        return model.handleKey(event, isTextEditing: true)
    }

    override func keyDown(with event: NSEvent) {
        if !model.handleKey(event, isTextEditing: false) { super.keyDown(with: event) }
    }

    private func designPoint(_ event: NSEvent) -> NSPoint {
        let point = convert(event.locationInWindow, from: nil)
        return NSPoint(x: (point.x - canvasOrigin.x) / scale, y: (point.y - canvasOrigin.y) / scale)
    }

    override func mouseDown(with event: NSEvent) {
        cancelDrag()
        let point = designPoint(event)
        guard let hit = regions.last(where: { $0.rect.contains(point) }), let action = hit.action else { return }
        if model.prompt != nil {
            switch action {
            case .choice, .input: break
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
        case let .choice(index): model.choosePromptOption(at: index)
        case let .complete(command):
            model.updateInput(command + " ")
            input.stringValue = model.inputText
            focusInput(selection: nil)
        case let .draft(command):
            model.startCommand()
            model.updateInput(command + " ")
            synchronize()
        case let .command(command): model.runCommand(command)
        case let .calcRow(index): model.selectCalcEntry(at: index)
        case .input:
            if model.isTextInputActive {
                focusInput(selection: (input.currentEditor() as? NSTextView)?.selectedRange() ?? savedSelection)
            }
            else if model.prompt == nil { model.startCommand() }
        }
        synchronize()
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
        let showsOutput = model.buffer == nil || model.prompt != nil || model.inputKind == .command
            || (model.inputKind != nil && model.buffer != .calc)
        if let buffer = model.buffer {
            context.saveGState()
            if showsOutput { context.clip(to: CGRect(x: 40, y: 24, width: 1360, height: 624)) }
            drawBuffer(buffer)
            context.restoreGState()
            if showsOutput { regions.removeAll { $0.rect.maxY > 648 } }
        } else { drawList() }
        if showsOutput { drawOutput() }
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
                D.text("载入书签数据…", 720, 392, size: 15, color: D.teal, align: .center)
            } else if let issue = model.store.issue {
                D.icon("warn", x: 702, y: 324, size: 36, color: D.red)
                D.text("无法载入数据，原文件已保留", 720, 392, size: 15, color: D.red, bold: true, align: .center)
                D.text(issue, 720, 420, size: 12, color: D.muted, maxWidth: 1120, align: .center)
                D.text(":retry 重试", 680, 458, size: 12, color: D.teal, align: .right)
                D.text(":cd 更换数据目录", 760, 458, size: 12, color: D.teal)
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
                D.text("Enter 打开网址或用默认浏览器搜索“\(model.query)”", 720, 420, size: 12, color: D.muted, maxWidth: 1000, align: .center)
            } else {
                D.text("∅", 720, 352, size: 38, color: D.muted.withAlphaComponent(0.42), align: .center)
                D.text("还没有书签", 720, 402, size: 15, color: D.ink2, bold: true, align: .center)
                D.text("按 a 添加书签 · :restore 从备份恢复", 720, 428, size: 12, color: D.muted, align: .center)
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
            let suffix = item.expanded ? " · 已展开" : ""
            D.text(item.detail + suffix + (model.isOrganizing ? " · 固定" : ""), 1390, cy, size: 11.5, color: meta, maxWidth: 200, align: .right)
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
        let label = item.kind == .folder ? "移入「\(item.title)」" : target.merge && mergeReady ? "＋ 创建文件夹" : target.merge ? "停留以创建文件夹" : "插入到此"
        let width = min(500, D.width(label, size: 11) + 16)
        D.green.setStroke()
        NSBezierPath(rect: NSRect(x: 46, y: y + 1, width: 1348, height: 30)).stroke()
        D.rule(46, target.before ? y : y + 31, 1348, color: D.green, height: 2)
        D.rect(NSRect(x: 1394 - width, y: y - 20, width: width, height: 18), D.mint)
        D.text(label, 1402 - width, y - 11, size: 11, color: D.pine, bold: true, maxWidth: width - 16)
    }

    private func drawOutput() {
        typealias D = TerminalDrawing
        D.rect(NSRect(x: 40, y: 664, width: 1360, height: 72), D.paper)
        D.rule(40, 664, 1360)
        if let prompt = model.prompt {
            D.rect(NSRect(x: 40, y: 665, width: 1360, height: 71), D.surface)
            D.rect(NSRect(x: 40, y: 664, width: 3, height: 72), D.yellow)
            D.text("PROMPT · \(prompt.command.uppercased())", 54, 678, size: 10.5, color: D.muted)
            D.text(prompt.total > 0 ? "步骤 \(prompt.step + 1)/\(prompt.total) · Shift+Tab 返回 · Esc 取消" : "Esc 取消", 1390, 678, size: 10.5, color: D.muted, align: .right)
            if !prompt.choices.isEmpty {
                let start = max(0, prompt.selectedChoice - 2)
                for index in start..<min(start + 3, prompt.choices.count) {
                    let choice = prompt.choices[index]
                    let y = 698 + CGFloat(index - start) * 14
                    let selected = index == prompt.selectedChoice
                    if selected { D.rect(NSRect(x: 40, y: y - 8, width: 1360, height: 16), D.ink) }
                    D.text(String(format: "%02d", index + 1), 50, y, size: 11.5, color: selected ? D.yellow : D.muted)
                    D.text(choice.label, 78, y, size: 12.5, color: selected ? D.paper : D.ink, maxWidth: 800)
                    D.text(choice.detail, 1390, y, size: 11, color: selected ? D.mint : D.muted, maxWidth: 480, align: .right)
                    hit(NSRect(x: 40, y: y - 7, width: 1360, height: 14), choice.label + " " + choice.detail, .choice(index), selected: selected)
                }
            } else {
                D.text(prompt.error ?? prompt.hint, 54, 700, size: 12.5, color: prompt.error == nil ? D.ink2 : D.red, maxWidth: 1320)
                let context = prompt.context ?? "Enter 确认 · Esc 取消；未提交的输入会保留。"
                D.text(context, 54, 718, size: 11.5, color: D.muted, maxWidth: 1320)
                hit(NSRect(x: 54, y: 708, width: 1320, height: 24), context)
            }
            return
        }
        if let issue = model.store.issue, model.inputKind == nil {
            D.text("DATA ERROR · 已保留现有数据", 40, 679, size: 10.5, color: D.red)
            D.text(issue, 40, 700, size: 12.5, color: D.red, maxWidth: 1360)
            D.text(":retry 重试载入 · :cd 更换数据目录 · :log 查看日志", 40, 720, size: 11.5, color: D.muted)
            hit(NSRect(x: 40, y: 688, width: 1360, height: 24), issue)
            return
        }
        if model.isOrganizing {
            D.text("整理 / ORGANIZE", 40, 678, size: 11, color: D.green, bold: true)
            D.text("j/k 选择 · Shift+↑/↓ 或 J/K 调整顺序 · m 移到文件夹 · D 删除确认", 40, 699, size: 13, color: D.ink2)
            D.text("文件夹置顶且固定；拖动书签排序、移入文件夹，或在根书签中央停留创建文件夹。o / Esc 完成。", 40, 718, size: 12, color: D.muted)
            return
        }
        let prefix = model.inputKind == .command && !model.inputText.contains(where: { $0.isWhitespace }) ? model.inputText.lowercased() : nil
        let commands = prefix.map { prefix in model.commands.filter { $0.name.hasPrefix(prefix) }.prefix(3) }
        D.text(commands?.isEmpty == false ? "COMMANDS · Tab 补全 · ↑↓ 历史" : "OUTPUT", 40, 679, size: 10.5, color: D.muted)
        D.text(":log 查看全部", 1400, 679, size: 10.5, color: D.muted, align: .right)
        hit(NSRect(x: 1280, y: 666, width: 120, height: 22), "查看全部日志", .command("log"))
        if let commands, !commands.isEmpty {
            for (index, command) in commands.enumerated() {
                let y = 698 + CGFloat(index) * 16
                D.text(String(format: "%02d", index + 1), 48, y, size: 11.5, color: D.muted)
                D.text(":" + command.name, 74, y, size: 12.5)
                D.text(command.summary, 1392, y, size: 11, color: D.muted, maxWidth: 1000, align: .right)
                hit(NSRect(x: 40, y: y - 8, width: 1360, height: 16), command.usage + " " + command.summary, .complete(command.name))
            }
        } else if model.logs.isEmpty {
            D.text("就绪。输入 : 打开命令，/ 搜索，a 添加，? 帮助。", 40, 704, size: 12, color: D.muted)
        } else {
            for (index, entry) in model.logs.suffix(3).enumerated() {
                let y = 698 + CGFloat(index) * 16
                D.text(entry.time, 40, y, size: 11.5, color: D.muted, maxWidth: 64)
                D.text(entry.text, 106, y, size: 12.5, color: D.level(entry.level), maxWidth: 1294)
                hit(NSRect(x: 106, y: y - 8, width: 1294, height: 16), entry.text)
            }
        }
    }

    private func drawChrome() {
        typealias D = TerminalDrawing
        if model.prompt != nil {
            D.rect(NSRect(x: 0, y: 752, width: 1440, height: 40), D.surface)
            D.rect(NSRect(x: 0, y: 752, width: 3, height: 40), D.yellow)
        }
        D.rule(0, 752, 1440)
        let isCalc = model.buffer == .calc && model.inputKind == .calc
        let symbol = isCalc ? "=" : model.inputKind == .search ? "/" : model.inputKind != nil || model.prompt != nil ? ":" : "›"
        let symbolColor = isCalc ? D.green : model.inputKind == .search ? D.teal
            : model.inputKind != nil || model.prompt != nil ? D.amber : D.green
        D.text(symbol, 40, 773, size: 17, color: symbolColor, bold: true)
        if let prompt = model.prompt { D.text(prompt.label, 58, 773, size: 13, color: D.muted, maxWidth: inputX - 70) }
        else if isCalc { D.text(Self.calcLabel, 58, 773, size: 13, color: D.muted, maxWidth: inputX - 70) }
        if !model.isTextInputActive {
            if model.prompt != nil { D.text(model.inputText, inputX, 773, size: 15.5, maxWidth: 1400 - inputX - hintWidth - 24) }
            else {
                D.text(model.buffer == .settings ? ": 输入命令 · :help 查看帮助" : ": 打开命令 · / 搜索 · ? 帮助", inputX + 2, 773, color: D.muted)
            }
        }
        if !commandHint.isEmpty {
            let hintColor: NSColor = model.prompt?.error != nil ? D.red
                : isCalc && model.calcFeedback != nil ? D.level(model.calcFeedbackLevel) : D.muted
            D.text(commandHint, 1400, 773, size: 12, color: hintColor, maxWidth: hintWidth, align: .right)
            hit(NSRect(x: 1400 - hintWidth, y: 752, width: hintWidth, height: 40), commandHint, .input)
        }
        hit(NSRect(x: 40, y: 752, width: 1360 - hintWidth - 24, height: 40), "命令行输入", .input)
        D.rect(NSRect(x: 0, y: 796, width: 1440, height: 36), D.forest)
        D.text(model.modeLabel, 40, 815.5, size: 12.5, color: D.yellow, bold: true, maxWidth: 800)
        if model.buffer == nil {
            let status: String?
            if !model.query.isEmpty {
                status = "“\(model.query)” · \(model.items.count) 条结果"
            } else if !model.expandedGroupIDs.isEmpty {
                status = "已展开 \(model.expandedGroupIDs.count) 个文件夹"
            } else {
                status = nil
            }
            if let status {
                let x = 72 + D.width(model.modeLabel, size: 12.5, bold: true)
                D.text("· \(status)", x, 815.5, size: 12.5,
                       color: D.paper.withAlphaComponent(0.82), maxWidth: max(0, 740 - x))
            }
        }
        if model.prompt == nil, model.inputKind == nil, !model.busy {
            D.text(model.buffer == .settings ? ":set <key> <value> · :help 帮助 · Esc 返回" : ": 命令 · ? 帮助",
                   1400, 815.5, size: 12, color: D.mint, maxWidth: 640, align: .right)
        }
        drawShortcutHints()
    }

    private func drawShortcutHints() {
        typealias D = TerminalDrawing
        var x: CGFloat = 40
        func key(_ key: String, _ label: String) {
            let width = D.key(key, x: x, y: 856)
            let labelWidth = D.width(label, size: 11.5)
            D.text(label, x + width + 6, 856.5, size: 11.5, color: D.muted)
            hit(NSRect(x: x, y: 845, width: width + 6 + labelWidth, height: 22), "\(key) \(label)")
            x += width + 24 + labelWidth
        }

        // 与按键路由保持相同优先级，提示流不能泄漏底层列表或缓冲区的快捷键。
        if model.busy {
            D.text("正在处理，请稍候…", 40, 856.5, size: 11.5, color: D.muted)
            return
        }
        if let prompt = model.prompt {
            switch prompt.command {
            case "hotkey":
                key("组合键", "录入新快捷键")
                key("Esc", "取消录入")
                return
            case "delete":
                key("y", "确认删除")
                key("N / Enter / Esc", "取消删除")
                return
            case "edit":
                key("Tab / ⇧Tab", "切换标题 / 网址")
                key("Enter", "保存全部")
            default:
                if !prompt.choices.isEmpty {
                    key("Tab / ↑↓", prompt.field == "path" || prompt.field == "file" ? "补全路径" : "选择位置")
                }
                if (prompt.command == "add" || prompt.command == "move") && prompt.step > 0 {
                    key("⇧Tab", "返回上一步")
                }
                let submit: String
                switch prompt.command {
                case "add":
                    submit = prompt.step < 2 ? "下一步"
                        : prompt.step == 2 ? "确认位置" : "创建并添加"
                case "move": submit = prompt.step == 0 ? "确认目标" : "创建并移动"
                case "rename": submit = "保存名称"
                case "mkdir": submit = "创建文件夹"
                case "backup": submit = "导出备份"
                case "restore": submit = "恢复并替换全部数据"
                case "cd": submit = "切换目录"
                default: submit = "提交"
                }
                key("Enter", submit)
            }
            key("Esc", "取消")
            return
        }
        if model.inputKind == .command {
            key("Tab / ⇧Tab", "补全命令")
            key("↑↓", "命令历史")
            key("Enter", "执行命令")
            key("Esc", model.buffer == .calc ? "返回算式" : "取消命令")
            return
        }
        if model.inputKind == .search {
            if !model.items.isEmpty { key("↑↓", "选择结果") }
            key("Enter", model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "结束搜索"
                : model.items.isEmpty ? "打开网址 / 网页搜索" : "打开结果")
            key("Esc", "清空并退出搜索")
            return
        }
        if let buffer = model.buffer {
            switch buffer {
            case .calc:
                if model.isCalcActive {
                    key("Enter / =", "计算")
                    if !model.calcHistory.isEmpty { key("↑↓", "选择历史") }
                    key("c", "复制结果")
                }
                key(":", "命令")
                key("Esc", model.isCalcActive ? "关闭并保留算式" : "返回算式")
            case .settings:
                key(":", "输入设置命令")
                key(":help", "帮助")
                key("Esc", "返回书签")
            case .help, .log, .job:
                key("j/k / ↑↓", "滚动")
                key("PgUp / PgDn", "翻屏")
                key("g / G", "首行 / 末行")
                key(":", "命令")
                if buffer == .log { key(":clear", "清空日志") }
                key("/", "搜索书签")
                key("Esc", "返回书签")
            }
            return
        }

        let selected = model.items.indices.contains(model.selectedIndex) ? model.items[model.selectedIndex] : nil
        let searching = !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let selected {
            key("j/k / ↑↓", "选择")
            if selected.kind == .folder {
                key("Enter / Tab", selected.expanded ? "折叠" : "展开")
                key("r", "重命名")
            } else {
                key("Enter", "打开")
                if model.isOrganizing, model.query.isEmpty { key("⇧↑↓ / K/J", "调整顺序") }
                else if !model.isOrganizing { key("e", "编辑") }
                key("m", "移动")
                key("c", "复制链接")
            }
            if selected.kind == .bookmark || !model.document.bookmarks.contains(where: { $0.groupId == selected.id }) {
                key("D", "删除")
            }
        } else if searching {
            key("Enter", "打开网址 / 网页搜索")
        }
        if !searching, !model.document.groups.isEmpty {
            let allExpanded = model.document.groups.allSatisfy { model.expandedGroupIDs.contains($0.id) }
            key("z", allExpanded ? "全部折叠" : "全部展开")
        }
        if !model.isOrganizing {
            key("a", "添加")
            key("n", "新建文件夹")
            if !searching { key("o", "排序整理") }
        }
        key("/", "搜索")
        key(":", "命令")
        key("?", "帮助")
        if model.isOrganizing { key("o / Esc", "完成整理") }
        else if !model.query.isEmpty { key("Esc", "清空搜索") }
        else if let groupID = model.selectedGroupID(), model.expandedGroupIDs.contains(groupID) {
            key("Esc", "折叠当前文件夹")
        } else {
            key("Esc", model.expandedGroupIDs.isEmpty ? "收起窗口" : "折叠全部文件夹")
        }
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
                        switch action { case .choice, .input: break; default: return false }
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
