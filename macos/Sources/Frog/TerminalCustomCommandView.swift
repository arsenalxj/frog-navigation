import AppKit
import FrogCore

enum CustomCommandAction {
    case add, edit, copy, duplicate, delete, confirmDelete, save, cancel, run, search, results, stop, confirmStop, cancelStop
    case focusList, browseDirectory, acceptDirectory, leaveDirectory, directoryChoice(Int), field(Int), row(Int)
}

@MainActor
extension LauncherView {

    func performCustomAction(_ action: CustomCommandAction, activate: Bool) {
        guard !model.customSaving else { return }
        if model.customStopConfirmation {
            switch action {
            case .confirmStop: model.confirmCustomStop()
            case .cancelStop, .cancel: model.cancelCustomStop()
            default: break
            }
            return
        }
        if model.customScreen == .edit {
            switch action { case .save, .cancel, .directoryChoice, .field, .browseDirectory, .acceptDirectory, .leaveDirectory: break; default: return }
        }
        switch action {
        case .add: model.addCurrentObject()
        case .edit: if let command = model.customDisplayedCommand { model.beginCustomEdit(command) }
        case .copy: model.copyCurrentObject()
        case .duplicate: model.duplicateCurrentCommand()
        case .delete: model.requestCustomDelete()
        case .confirmDelete: model.confirmCustomDelete()
        case .save: model.saveCustomDraft()
        case .cancel: model.escapeCustomCommands()
        case .run: if let command = model.selectedCustomCommand { model.executeCustomCommand(command) }
        case .search: model.startCustomSearch()
        case .results: model.showCustomExecution()
        case .stop: model.requestCustomStop()
        case .confirmStop: model.confirmCustomStop()
        case .cancelStop: model.cancelCustomStop()
        case .focusList: model.selectCustomCommand(model.customIndex)
        case .browseDirectory: model.focusCustomDirectoryChoices()
        case .acceptDirectory: model.acceptCustomDirectoryChoice()
        case .leaveDirectory: model.leaveCustomDirectoryChoices()
        case let .directoryChoice(index): model.chooseCustomDirectoryCandidate(at: index, activate: activate)
        case let .field(index): model.selectCustomField(index)
        case let .row(index):
            model.selectCustomCommand(index)
            if activate, let command = model.selectedCustomCommand { model.executeCustomCommand(command) }
        }
    }

    func drawCustomShortcutHints() {
        if model.customSaving {
            TerminalDrawing.text("正在保存…", 40, 856.5, size: 11.5, color: TerminalDrawing.muted)
            return
        }
        var x: CGFloat = 40
        func key(_ shortcut: String, _ label: String, _ action: CustomCommandAction? = nil) {
            drawShortcutKey(shortcut, label, x: &x, action: action.map { .custom($0) })
        }
        if model.customStopConfirmation {
            key("y", "停止", .confirmStop)
            key("Esc", "取消", .cancelStop)
            return
        }
        switch model.customScreen {
        case .list:
            if model.inputKind == .search {
                if model.selectedCustomCommand != nil {
                    key("↑↓", "选择")
                    key("Tab", "进列表", .focusList)
                    key("Enter", "运行", .run)
                }
                key("Esc", "清空", .cancel)
            } else {
                key("/", "搜索", .search)
                key("a", "新建", .add)
                if model.selectedCustomCommand != nil {
                    key("e", "编辑", .edit)
                    key("⌘C", "复制", .copy)
                    key("⌘D", "副本", .duplicate)
                    key("⇧D", "删除", .delete)
                    key("Enter", "运行", .run)
                }
            }
        case .edit:
            if model.customDirectoryFocused {
                key("↑↓", "选择")
                key("←→", "浏览")
                key("Enter", "采纳", .acceptDirectory)
                key("⌘Enter", "保存草稿", .save)
                key("Esc", "取消浏览", .leaveDirectory)
            } else {
                key("Tab/⇧Tab", "切字段")
                if model.customField.isOption { key("←→", "改值") }
                if model.isCustomDirectoryEditing { key("⌘↓", "浏览目录", .browseDirectory) }
                key("Enter", "保存", .save)
                key("Esc", "放弃修改", .cancel)
            }
        case .execution:
            key("↑↓", "滚动")
            key("e", "编辑", .edit)
            key("Esc", "返回", .cancel)
        case .delete:
            key("y", "删除", .confirmDelete)
            key("Esc", "取消", .cancel)
        }
        if [.list, .execution].contains(model.customScreen), model.canStopCustomExecution, model.inputKind == nil {
            key("⌘.", "停止任务", .stop)
        }
    }

    func drawCustomCommands() {
        typealias D = TerminalDrawing
        let left: CGFloat = 72
        let right: CGFloat = 1368
        let screen = model.customScreen
        if let command = model.customDisplayedCommand {
            let color = screen == .delete || (screen == .execution && model.customExecutionFailed) ? D.red : D.green
            D.text(":" + (command.name.isEmpty ? "新命令" : command.name), left, 114, size: 40, color: color, bold: true, maxWidth: right - left)
            let subtitle = screen == .delete ? "只删除命令配置，不删除目录、应用或脚本。" : command.title + " · " + command.type.label
            D.text(subtitle, left, 150, size: 12, color: D.muted, maxWidth: right - left)
        } else {
            let message = model.customIssue != nil ? "自定义命令配置读取失败；现有文件已保留。"
                : !model.customLoaded ? "正在载入自定义命令…"
                : model.customCommands.isEmpty ? "尚无自定义命令" : "没有匹配的命令"
            D.text(message, left, 110, size: 14, color: D.muted, maxWidth: right - left)
        }
        D.rule(left, 168, right - left)
        let section: String
        switch screen {
        case .list: section = "COMMANDS · \(model.filteredCustomCommands.count) 条" + (model.customQuery.isEmpty ? "" : " · / " + model.customQuery)
        case .edit: section = "CONFIG · " + model.customScreenTitle
        case .delete: section = "CONFIRM"
        case .execution: section = "EXECUTION · " + model.customScreenTitle
        }
        D.text(section, left, 192, size: 10.5, color: D.muted, maxWidth: 600)
        switch screen {
        case .list:
            let commands = model.filteredCustomCommands
            let start = min(max(0, model.bufferOffset), commands.count)
            let end = min(commands.count, start + LauncherModel.calcVisibleRows)
            for index in start..<end {
                let command = commands[index]
                let y = 216 + CGFloat(index - start) * 26
                let selected = index == model.customIndex
                drawCustomSelection(y: y, selected: selected)
                D.text(String(format: "%02d", index + 1), left, y, size: 10, color: selected ? D.yellow : D.muted)
                D.text(":" + command.name, 100, y, size: 12.5, color: selected ? D.paper : D.ink, maxWidth: 200)
                D.text(command.title, 320, y, size: 12.5, color: selected ? D.paper : D.ink, maxWidth: 280)
                D.text(command.type.label, 624, y, size: 11, color: selected ? D.mint : D.muted, maxWidth: 130)
                D.text(command.type == .url ? command.target : command.directory, right, y, size: 11,
                       color: selected ? D.mint : D.green, maxWidth: 596, align: .right)
                hit(NSRect(x: 64, y: y - 11, width: 1312, height: 22), ":\(command.name)，\(command.title)，\(command.type.label)，\(command.directory)", .custom(.row(index)), selected: selected)
            }
        case .edit:
            if let command = model.customDraft {
                for (index, field) in model.customFields.enumerated() {
                    let y = 216 + CGFloat(index) * 26
                    let selected = index == model.customFieldIndex && !model.customDirectoryFocused
                    drawCustomSelection(y: y, selected: selected)
                    let value = model.customValue(field, command: command)
                    D.text(String(format: "%02d", index + 1), left, y, size: 10, color: selected ? D.yellow : D.muted)
                    D.text(model.customFieldLabel(field, command: command), 100, y, size: 11, color: selected ? D.mint : D.muted, maxWidth: 160)
                    D.text(value.isEmpty ? "（未填写）" : value, 272, y, size: 12.5, color: selected ? D.paper : D.ink, maxWidth: 966)
                    hit(NSRect(x: 64, y: y - 11, width: 1312, height: 22), model.customFieldLabel(field, command: command) + "：" + value, .custom(.field(index)), selected: selected)
                }
            }
        case .delete: break
        case .execution:
            let rows = model.customExecutionRows
            let start = min(max(0, model.bufferOffset), rows.count)
            let end = min(rows.count, start + LauncherModel.calcVisibleRows)
            for index in start..<end {
                let (key, value) = rows[index]
                let y = 216 + CGFloat(index - start) * 26
                D.text(String(format: "%02d", index + 1), left, y, size: 10, color: D.muted)
                D.text(key, 100, y, size: 11, color: D.muted, maxWidth: 160)
                D.text(value.isEmpty ? "（无）" : value, 272, y, size: 12.5,
                       color: key == "状态" ? (model.customExecutionFailed ? D.red : D.green) : D.ink, maxWidth: 1096)
                hit(NSRect(x: 64, y: y - 11, width: 1312, height: 22), key + "：" + value)
            }
            if rows.count > LauncherModel.calcVisibleRows { D.text("\(start + 1)–\(end) / \(rows.count) · 滚轮滚动", right, 700, size: 10, color: D.muted, align: .right) }
        }
        if model.customStopConfirmation {
            D.text("停止 :\(model.customExecutionCommand?.name ?? "") 的后台程序？进程将被终止。", left, 664, size: 12, color: D.red, maxWidth: 1296)
        } else if [.list, .execution].contains(screen), let command = model.customExecutionCommand {
            let status = model.customExecuting ? (model.canStopCustomExecution ? "运行中" : "正在交接") : "执行结果"
            let label = "\(status) · :\(command.name) · \(model.customExecutionSummary)"
            D.text(label, left, 664, size: 11, color: model.customExecutionFailed ? D.red : D.teal, maxWidth: 1030)
            hit(NSRect(x: left, y: 652, width: 1030, height: 24), "查看任务与结果：" + label, .custom(.results))
        }
        if model.isCustomDirectoryEditing, model.customDirectoryFocused { drawCustomDirectoryChoices() }
        if let issue = model.customIssue ?? model.customFeedback {
            D.text(issue, left, 700, size: 12, color: model.customIssue != nil || model.prompt?.error != nil ? D.red : D.amber, maxWidth: right - left)
            hit(NSRect(x: left, y: 688, width: right - left, height: 24), issue)
        }
    }

    private func drawCustomDirectoryChoices() {
        typealias D = TerminalDrawing
        let choices = model.prompt?.choices ?? []
        let selected = model.prompt?.selectedChoice ?? 0
        let start = max(0, selected - 9)
        let end = min(choices.count, start + 10)
        D.rule(72, 394, 1296)
        D.text("DIRECTORIES · \(choices.count) 项 · 目录浏览", 72, 414, size: 10.5, color: D.amber)
        if choices.isEmpty {
            D.text(model.customDirectoryLoading ? "正在读取目录…" : "无可用目录；返回路径字段继续输入。",
                   72, 444, size: 12.5, color: D.muted, maxWidth: 1296)
        }
        for index in start..<end {
            let choice = choices[index]
            let y = 444 + CGFloat(index - start) * 26
            let active = index == selected
            drawCustomSelection(y: y, selected: active)
            if active { D.text("›", 72, y, size: 14, color: D.yellow, bold: true) }
            let name = choice.detail == "current-directory" ? "使用当前目录 · " + choice.label
                : URL(fileURLWithPath: choice.label, isDirectory: true).lastPathComponent + "/"
            D.text(name, 100, y, size: 13, color: active ? D.mint : D.teal, maxWidth: 1268)
            hit(NSRect(x: 64, y: y - 11, width: 1312, height: 22), name, .custom(.directoryChoice(index)), selected: active)
        }
        if choices.count > 10 {
            D.text("\(start + 1)–\(end) / \(choices.count)", 1368, 700, size: 10, color: D.muted, align: .right)
        }
    }

    private func drawCustomSelection(y: CGFloat, selected: Bool) {
        guard selected else { return }
        TerminalDrawing.rect(NSRect(x: 64, y: y - 11, width: 1312, height: 22), TerminalDrawing.ink)
        TerminalDrawing.rect(NSRect(x: 64, y: y - 11, width: 3, height: 22), TerminalDrawing.yellow)
    }

    func drawCommandDiscovery() {
        let candidates = model.commandCandidates
        guard !candidates.isEmpty else { return }
        typealias D = TerminalDrawing
        let start = max(0, (model.commandCandidateIndex ?? 0) - 6)
        let end = min(candidates.count, start + 7)
        let top = 736 - CGFloat(end - start) * 26 - 54
        D.rect(NSRect(x: 40, y: top, width: 1360, height: 736 - top), D.paper)
        hit(NSRect(x: 40, y: top, width: 1360, height: 736 - top), "命令候选")
        D.rule(40, top, 1360)
        D.text("COMMANDS · \(candidates.count) 项", 72, top + 22, size: 10.5, color: D.muted)
        D.text("↑↓ 选择 · Tab / 点击补全 · Enter 执行 · ⌥↑↓ 历史", 1368, top + 22, size: 10.5, color: D.muted, align: .right)
        for index in start..<end {
            let command = candidates[index]
            let selected = index == model.commandCandidateIndex
            let y = top + 48 + CGFloat(index - start) * 26
            drawCustomSelection(y: y, selected: selected)
            D.text(":" + command.name, 72, y, size: 12.5, color: selected ? D.paper : D.teal, maxWidth: 240)
            D.text(command.summary, 320, y, size: 12.5, color: selected ? D.paper : D.ink, maxWidth: 620)
            D.text(command.detail, 1368, y, size: 10.5, color: selected ? D.mint : D.muted, maxWidth: 400, align: .right)
            hit(NSRect(x: 64, y: y - 11, width: 1312, height: 22), ":\(command.name)，\(command.summary)", .complete(command.name), selected: selected)
        }
    }
}
