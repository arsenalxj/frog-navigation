import AppKit
import FrogCore

enum CustomCommandAction {
    case add, edit, copy, duplicate, delete, confirmDelete, save, advanceOrSave, cancel, run, search, results, stop, confirmStop, cancelStop
    case focusList, browseDirectory, acceptDirectory, leaveDirectory, directoryChoice(Int), field(Int), option(Int), row(Int)
    case nextField, startCommand, openSettings, openHelp
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
            switch action {
            case .save, .advanceOrSave, .cancel, .directoryChoice, .field, .option, .nextField,
                 .browseDirectory, .acceptDirectory, .leaveDirectory:
                break
            default:
                return
            }
        }
        switch action {
        case .add: model.addCurrentObject()
        case .edit: if let command = model.customDisplayedCommand { model.beginCustomEdit(command) }
        case .copy: model.copyCurrentObject()
        case .duplicate: model.duplicateCurrentCommand()
        case .delete: model.requestCustomDelete()
        case .confirmDelete: model.confirmCustomDelete()
        case .save: model.saveCustomDraft()
        case .advanceOrSave: model.advanceOrSaveCustomDraft()
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
        case let .option(index):
            model.selectCustomOption(at: index)
            if activate, model.isCustomAdding { model.advanceOrSaveCustomDraft() }
        case .nextField: model.tabCustomField(backward: false)
        case .startCommand: model.startCommand()
        case .openSettings: model.openSettings()
        case .openHelp: model.openBuffer(.help)
        case let .row(index):
            model.selectCustomCommand(index)
            if activate, let command = model.selectedCustomCommand { model.executeCustomCommand(command) }
        }
    }

    func customShortcutHints() -> [ShortcutHint] {
        var hints: [ShortcutHint] = []
        func add(_ key: String, _ label: String, _ action: CustomCommandAction? = nil) {
            hints.append(ShortcutHint(key: key, label: label, action: action.map { .custom($0) }))
        }
        if model.customStopConfirmation {
            add("y", "停止", .confirmStop)
            add("Esc", "取消", .cancelStop)
            return hints
        }
        switch model.customScreen {
        case .list:
            if model.inputKind == .search {
                if model.selectedCustomCommand != nil {
                    add("↑↓", "选择")
                    add("Tab", "进列表", .focusList)
                    add("Enter", "运行", .run)
                }
                add("Esc", "清空", .cancel)
            } else {
                if model.selectedCustomCommand != nil {
                    add("↑↓", "选择")
                    add("Enter", "运行", .run)
                }
                add("a", "新建", .add)
                if model.selectedCustomCommand != nil {
                    add("e", "编辑", .edit)
                    add("⌘C", "复制", .copy)
                    add("⌘D", "副本", .duplicate)
                    add("⇧D", "删除", .delete)
                }
                add("/", model.customQuery.isEmpty ? "搜索" : "继续搜索", .search)
                add(":", "命令", .startCommand)
                add(",", "设置", .openSettings)
                add("?", "帮助", .openHelp)
                if model.canStopCustomExecution { add("⌘.", "停止任务", .stop) }
                add("Esc", model.customQuery.isEmpty ? "返回" : "清空", .cancel)
            }
        case .edit:
            if model.customDirectoryFocused {
                add("↑↓", "选择")
                add("←→", "浏览")
                add("Enter", "采纳", .acceptDirectory)
                add("Tab", "切字段", .nextField)
                add("⌘Enter", "保存草稿", .save)
                add("Esc", "取消浏览", .leaveDirectory)
            } else {
                let isLastField = model.customFieldIndex == model.customFields.count - 1
                add("Tab", "切字段", .nextField)
                if model.customField.isOption { add("↑↓/←→", "改值") }
                if model.isCustomDirectoryEditing { add("⌘↓", "浏览目录", .browseDirectory) }
                if model.isCustomAdding && !isLastField {
                    add("Enter", "下一步", .advanceOrSave)
                    add("⌘Enter", "保存", .save)
                } else {
                    add("Enter", "保存", .advanceOrSave)
                }
                add("Esc", "放弃修改", .cancel)
            }
        case .execution:
            add("↑↓", "滚动")
            add("e", "编辑", .edit)
            if model.canStopCustomExecution { add("⌘.", "停止任务", .stop) }
            add(":", "命令", .startCommand)
            add("Esc", "返回", .cancel)
        case .delete:
            add("y", "删除", .confirmDelete)
            add("Esc", "取消", .cancel)
        }
        return hints
    }

    func drawCustomCommands() {
        typealias D = TerminalDrawing
        let left: CGFloat = 72
        let right: CGFloat = 1368
        let screen = model.customScreen
        if let command = model.customDisplayedCommand {
            let color = screen == .delete || (screen == .execution && model.customExecutionFailed) ? D.red : D.green
            D.text(":" + (command.name.isEmpty ? "新命令" : command.name), left, 114, size: 40, color: color, bold: true, maxWidth: right - left)
            let subtitle = screen == .delete ? "仅删除命令配置，不影响本地文件" : command.title + " · " + command.type.label
            D.text(subtitle, left, 150, size: 12, color: D.muted, maxWidth: right - left)
        } else {
            let message = model.customIssue != nil ? "读取失败，原文件已保留"
                : !model.customLoaded ? "正在载入…"
                : model.customCommands.isEmpty ? "暂无自定义命令" : "没有匹配的命令"
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
                    let emptyColor = selected ? D.paper.withAlphaComponent(0.6) : D.muted
                    D.text(value.isEmpty ? "（未填写）" : value, 272, y, size: 12.5, color: value.isEmpty ? emptyColor : (selected ? D.paper : D.ink), maxWidth: 966)
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
            if rows.count > LauncherModel.calcVisibleRows { D.text("\(start + 1)–\(end) / \(rows.count)", right, 700, size: 10, color: D.muted, align: .right) }
        }
        if model.customStopConfirmation {
            D.text("停止 :\(model.customExecutionCommand?.name ?? "")？后台进程将被终止", left, 664, size: 12, color: D.red, maxWidth: 1296)
        } else if [.list, .execution].contains(screen), let command = model.customExecutionCommand {
            let status = model.customExecuting ? (model.canStopCustomExecution ? "运行中" : "正在打开") : "结果"
            let label = "\(status) · :\(command.name) · \(model.customExecutionSummary)"
            D.text(label, left, 664, size: 11, color: model.customExecutionFailed ? D.red : D.teal, maxWidth: 1030)
            hit(NSRect(x: left, y: 652, width: 1030, height: 24), "查看执行结果：" + label, .custom(.results))
        }
        if model.isCustomDirectoryEditing, model.customDirectoryFocused {
            drawCustomDirectoryChoices()
        } else if screen == .edit, model.customField.isOption, let draft = model.customDraft {
            drawCustomOptionChoices(command: draft)
        }
        if let issue = model.customIssue ?? model.customFeedback {
            D.text(issue, left, 700, size: 12, color: model.customIssue != nil || model.prompt?.error != nil ? D.red : D.amber, maxWidth: right - left)
            hit(NSRect(x: left, y: 688, width: right - left, height: 24), issue)
        }
    }

    private func drawCustomOptionChoices(command: CustomCommand) {
        typealias D = TerminalDrawing
        let options = model.customOptionItems
        let title = model.customFieldLabel(model.customField, command: command)
        D.rule(72, 394, 1296)
        D.text("OPTIONS · \(title)", 72, 414, size: 10.5, color: D.amber)
        if options.isEmpty {
            D.text("未检测到受支持终端（Terminal / iTerm2 / Ghostty）", 72, 444, size: 12.5, color: D.muted, maxWidth: 1296)
            return
        }
        for (index, option) in options.enumerated() {
            let y = 444 + CGFloat(index) * 26
            drawCustomSelection(y: y, selected: option.selected)
            D.text(String(format: "%02d", index + 1), 72, y, size: 10, color: option.selected ? D.yellow : D.muted)
            D.text(option.label, 100, y, size: 13, color: option.selected ? D.paper : D.ink, maxWidth: 1200)
            if option.selected {
                D.text("当前", 1368, y, size: 10.5, color: D.mint, align: .right)
            }
            hit(NSRect(x: 64, y: y - 11, width: 1312, height: 22), option.label, .custom(.option(index)), selected: option.selected)
        }
    }

    private func drawCustomDirectoryChoices() {
        typealias D = TerminalDrawing
        let choices = model.prompt?.choices ?? []
        let selected = model.prompt?.selectedChoice ?? 0
        let start = max(0, selected - 9)
        let end = min(choices.count, start + 10)
        D.rule(72, 394, 1296)
        D.text("DIRECTORIES · \(choices.count) 项", 72, 414, size: 10.5, color: D.amber)
        if choices.isEmpty {
            D.text(model.customDirectoryLoading ? "正在读取目录…" : "无子目录，可返回路径框直接输入",
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
