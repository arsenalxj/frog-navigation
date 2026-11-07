import AppKit
import FrogCore

enum CustomCommandAction {
    case add, edit, copy, delete, confirmDelete, save, cancel, run, search, directoryChoice(Int), field(Int), row(Int)
}

@MainActor
extension LauncherView {

    func performCustomAction(_ action: CustomCommandAction, activate: Bool) {
        guard !model.customSaving else { return }
        if model.customScreen == .edit {
            switch action { case .save, .cancel, .directoryChoice, .field: break; default: return }
        }
        switch action {
        case .add: model.beginCustomEdit()
        case .edit: if let command = model.customDisplayedCommand { model.beginCustomEdit(command) }
        case .copy: if let command = model.selectedCustomCommand { model.beginCustomEdit(command, copy: true) }
        case .delete: model.requestCustomDelete()
        case .confirmDelete: model.confirmCustomDelete()
        case .save: model.saveCustomDraft()
        case .cancel: model.escapeCustomCommands()
        case .run: if let command = model.selectedCustomCommand { model.executeCustomCommand(command) }
        case .search: model.startCustomSearch()
        case let .directoryChoice(index): model.chooseCustomDirectoryCandidate(at: index)
        case let .field(index): model.selectCustomField(index)
        case let .row(index):
            model.selectCustomCommand(index)
            if activate, let command = model.selectedCustomCommand { model.beginCustomEdit(command) }
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
                : model.customCommands.isEmpty ? "按 a 新建自定义命令，例如 aiomp → 指定目录运行 omp" : "没有匹配的命令"
            D.text(message, left, 110, size: 14, color: D.muted, maxWidth: right - left)
        }
        D.rule(left, 168, right - left)
        let section: String
        switch screen {
        case .list: section = "COMMANDS · \(model.filteredCustomCommands.count) 条" + (model.customQuery.isEmpty ? "" : " · / " + model.customQuery)
        case .edit: section = "CONFIG · " + model.customScreenTitle
        case .delete: section = "CONFIRM · y / N"
        case .execution: section = "EXECUTION · " + model.customScreenTitle
        }
        D.text(section, left, 192, size: 10.5, color: D.muted, maxWidth: 600)
        var controls: [(String, CustomCommandAction)] = []
        switch screen {
        case .list:
            controls = [("/ 搜索", .search), ("a 新建", .add)]
            if model.selectedCustomCommand != nil { controls += [("e 编辑", .edit), ("c 复制", .copy), ("D 删除", .delete), ("Enter 运行", .run)] }
        case .edit: controls = [("⌘Enter 保存", .save), ("Esc 取消", .cancel)]
        case .execution: controls = [("e 编辑", .edit), ("Esc 返回", .cancel)]
        case .delete: controls = [("y 确认删除", .confirmDelete), ("Esc 取消", .cancel)]
        }
        var end = right
        for (label, action) in controls.reversed() {
            let width = D.width(label, size: 10.5)
            D.text(label, end, 192, size: 10.5, color: D.muted, align: .right)
            hit(NSRect(x: end - width - 8, y: 181, width: width + 16, height: 22), label, .custom(action))
            end -= width + 24
        }
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
                    let selected = index == model.customFieldIndex
                    drawCustomSelection(y: y, selected: selected)
                    let value = model.customValue(field, command: command)
                    D.text(String(format: "%02d", index + 1), left, y, size: 10, color: selected ? D.yellow : D.muted)
                    D.text(field.label, 100, y, size: 11, color: selected ? D.mint : D.muted, maxWidth: 160)
                    D.text(value.isEmpty ? "（未填写）" : value, 272, y, size: 12.5, color: selected ? D.paper : D.ink, maxWidth: 966)
                    if field.isOption { D.text("←→ / 空格改值", right, y, size: 10.5, color: selected ? D.mint : D.muted, align: .right) }
                    hit(NSRect(x: 64, y: y - 11, width: 1312, height: 22), field.label + "：" + value, .custom(.field(index)), selected: selected)
                    if field == .directory {
                        let badge = model.customDirectoryBrowsing ? "浏览中 · Esc 退出" : "Enter 浏览目录"
                        D.text(badge, right, y, size: 10.5,
                               color: selected ? D.mint : (model.customDirectoryBrowsing ? D.amber : D.teal), align: .right)
                    }
                }
            }
        case .delete:
            if let command = model.selectedCustomCommand {
                D.text("确认删除 :\(command.name)？按 y 确认，n / Enter / Esc 取消。", left, 216, size: 12.5, color: D.red, maxWidth: right - left)
            }
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
        if model.isCustomDirectoryEditing { drawCustomDirectoryChoices() }
        if let issue = model.customIssue ?? model.customFeedback {
            D.text(issue, left, 700, size: 12, color: model.customIssue != nil || model.prompt?.error != nil ? D.red : D.amber, maxWidth: right - left)
            hit(NSRect(x: left, y: 688, width: right - left, height: 24), issue)
        }
        let note: String
        switch screen {
        case .list: note = "↑↓ 选择 · 点击选中 / 双击编辑 · Enter 真实运行 · 配置独立保存，不进入书签备份"
        case .edit: note = model.customDirectoryBrowsing
                ? "浏览目录：↑↓ 移动 · Tab 选择并进入 · ⇧Tab 上一级 · Enter 退出浏览（保留当前路径）"
                : model.isCustomDirectoryEditing
                ? "相对路径基准：\(model.customDirectoryBase.path) · ↑↓ 切字段 · Enter 浏览目录 · ⌘Enter 保存"
                : "↑↓ 切换字段 · ←→ / 空格改值 · Enter 下一项 · ⌘Enter 保存 · 参数 {args} / 网址 {query}"
        case .delete: note = "仅删除命令配置，不删除目标文件 · n / Enter / Esc 取消"
        case .execution: note = model.customExecuting
                ? "后台程序运行中 · Esc 终止 · 其余终端／浏览器只报告启动交接"
                : "终端 / 浏览器只报告启动交接；实际命令错误留在终端 · 无终端程序显示退出状态与输出"
        }
        D.text(note, left, 726, size: 10, color: D.muted, maxWidth: right - left)
    }

    private func drawCustomDirectoryChoices() {
        typealias D = TerminalDrawing
        let choices = model.prompt?.choices ?? []
        let selected = model.prompt?.selectedChoice ?? 0
        let browsing = model.customDirectoryBrowsing
        let start = max(0, selected - 9)
        let end = min(choices.count, start + 10)
        D.rule(72, 394, 1296)
        let state = browsing ? "BROWSING" : "READY · Enter 进入"
        D.text("DIRECTORIES · \(choices.count) 项 · \(state)", 72, 414, size: 10.5,
               color: browsing ? D.amber : D.muted)
        D.text(browsing ? "↑↓ 移动 · Tab 选择并进入 · ⇧Tab 上一级 · Enter 退出浏览" : "↑↓ 切字段 · Enter 浏览目录 · 直接输入可筛选",
               1368, 414, size: 10.5, color: D.muted, align: .right)
        if choices.isEmpty {
            D.text(model.customDirectoryLoading ? "正在读取目录…" : "无匹配子目录，或目录不可读；可继续输入路径，⌘Enter 保存。",
                   72, 444, size: 12.5, color: D.muted, maxWidth: 1296)
        }
        for index in start..<end {
            let choice = choices[index]
            let y = 444 + CGFloat(index - start) * 26
            let active = browsing && index == selected
            drawCustomSelection(y: y, selected: active)
            if active { D.text("›", 72, y, size: 14, color: D.yellow, bold: true) }
            let name = URL(fileURLWithPath: choice.label, isDirectory: true).lastPathComponent + "/"
            D.text(name, 100, y, size: 13, color: active ? D.mint : D.teal, maxWidth: 1268)
            hit(NSRect(x: 64, y: y - 11, width: 1312, height: 22), choice.label, .custom(.directoryChoice(index)), selected: active)
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
