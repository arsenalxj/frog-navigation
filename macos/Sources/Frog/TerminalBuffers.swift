import AppKit

@MainActor
extension LauncherView {
    func drawBuffer(_ buffer: TerminalBuffer) {
        typealias D = TerminalDrawing
        D.text("BUFFER", 40, 36, size: 10, color: D.muted)
        D.text("[\(buffer.rawValue)]", 102, 36, size: 13, bold: true)
        let hint: String
        switch buffer {
        case .settings: hint = ""
        case .help: hint = "Esc 返回 · : 输入命令"
        case .log: hint = ":clear 清空 · Esc 返回"
        case .job: hint = "Esc 返回 · :log 查看日志"
        case .calc: hint = "\(model.calcHistory.count) 条历史 · Esc 关闭"
        case .commands: hint = "\(model.customCommands.count) 条命令 · macOS · \(model.customScreenTitle) · Esc 返回"
        }
        D.text(hint, 1400, 36, size: 10.5, color: D.muted, align: .right)
        D.rule(40, 50, 1360)
        switch buffer {
        case .settings: drawSettings()
        case .help: drawHelp()
        case .log: drawLog()
        case .job: drawJob()
        case .calc: drawCalc()
        case .commands: drawCustomCommands()
        }
    }

    private func drawSettings() {
        typealias D = TerminalDrawing
        D.text("设置项", 130, 84, size: 10.5, color: D.muted)
        D.text("当前值", 304, 84, size: 10.5, color: D.muted)
        D.text("命令", 840, 84, size: 10.5, color: D.muted)
        let start = min(max(0, model.bufferOffset), model.settingsRows.count)
        let end = min(model.settingsRows.count, start + 31)
        for index in start..<end {
            let row = model.settingsRows[index]
            let y = 116 + CGFloat(index - start) * 20
            D.text(String(format: "%03d", index + 1), 96, y, size: 10, color: D.muted.withAlphaComponent(0.65))
            switch row.kind {
            case .blank: break
            case .value:
                let flashed = model.flashSetting == row.key
                D.text(row.key, 130, y, size: 12, color: D.teal, maxWidth: 146)
                D.text("=", 286, y, size: 12, color: D.muted)
                D.text(row.value, 304, y, size: 12, color: flashed ? D.amber : D.level(row.level), bold: true, maxWidth: 496)
                if flashed {
                    let x = 312 + min(480, D.width(row.value, size: 12, bold: true))
                    D.text("←", x, y, size: 11, color: D.amber)
                }
                hit(NSRect(x: 130, y: y - 10, width: 670, height: 20), "\(row.key) = \(row.value)")
            case .section, .note, .action:
                let text = row.key.isEmpty ? row.value : row.key
                D.text(text, 130, y, size: 12, color: row.kind == .section ? D.green : D.level(row.level),
                       maxWidth: row.command.isEmpty ? 1260 : 670)
                hit(NSRect(x: 130, y: y - 10, width: row.command.isEmpty ? 1260 : 670, height: 20), text)
            }
            if !row.command.isEmpty {
                D.text(row.command, 840, y, size: 10.5, color: D.muted, maxWidth: 550)
                hit(NSRect(x: 840, y: y - 10, width: 550, height: 20), row.command)
            }
        }
        bufferPosition(start: start, end: end, count: model.settingsRows.count)
    }

    private func drawHelp() {
        typealias D = TerminalDrawing
        D.text("NAME", 64, 84, size: 12, color: D.green, bold: true)
        D.text("青蛙导航 — 本地书签启动台。所有操作在命令行完成。", 340, 84, size: 12)
        D.text("SYNOPSIS", 64, 114, size: 12, color: D.green, bold: true)
        D.text("frog [command] · j/k 选择 · : 命令 · / 搜索", 340, 114, size: 12)
        D.text("COMMANDS", 64, 148, size: 12, color: D.green, bold: true)
        let start = min(max(0, model.bufferOffset), model.commands.count)
        let end = min(model.commands.count, start + 21)
        for index in start..<end {
            let command = model.commands[index]
            let y = 172 + CGFloat(index - start) * 20
            D.text(":" + command.name, 64, y, size: 12, color: D.teal, bold: true, maxWidth: 260)
            D.text(command.summary, 340, y, size: 11.5, maxWidth: 400)
            D.text(command.usage + (command.detail.isEmpty ? "" : " · " + command.detail), 760, y, size: 10.5, color: D.muted, maxWidth: 250)
            hit(NSRect(x: 64, y: y - 10, width: 946, height: 20), "\(command.usage)，\(command.summary)。\(command.detail)", .draft(command.name))
        }
        D.rect(NSRect(x: 1030, y: 142, width: 1, height: 442), D.line)
        D.text("KEYS · 列表模式", 1080, 148, size: 12, color: D.green, bold: true)
        let shortcuts = [
            ("j/k · ↑/↓", "移动"), ("g/G", "首项 / 末项"), ("PageUp/Down", "滚动"), ("Enter", "打开 / 确认"),
            ("/", "搜索"), (":", "命令"), ("a · ⌘N", "添加书签"), ("n", "新建文件夹"), ("e", "编辑书签"),
            ("r", "重命名文件夹"), ("m", "移动书签"), ("D", "删除确认"), ("c / C", "复制链接"), ("o", "整理"),
            ("Shift+↑/↓", "书签排序"), ("Tab", "展开 / 折叠"), ("z", "全部展开"), ("⌘,", "设置"), ("?", "帮助"), ("Esc", "取消 / 返回")
        ]
        for (index, shortcut) in shortcuts.enumerated() {
            let y = 172 + CGFloat(index) * 20
            D.text(shortcut.0, 1080, y, size: 11, color: D.teal, bold: true, maxWidth: 125)
            D.text(shortcut.1, 1210, y, size: 11.5, maxWidth: 184)
        }
        D.rule(64, 584, 936)
        D.text("EXAMPLES", 64, 604, size: 12, color: D.green, bold: true)
        let examples = [
            ("add", "逐项输入网址 / 标题 / 位置"),
            ("edit url", "修改当前书签网址"),
            ("delete", "命令行 y/N 确认删除"),
            ("set corner right-up", "修改屏幕触角"),
            ("backup", "输入备份文件路径，导出 JSON"),
            ("calc", "打开计算器；c 复制结果")
        ]
        for (index, example) in examples.enumerated() {
            let y = 626 + CGFloat(index) * 17
            D.text(":" + example.0, 64, y, size: 11.5, color: D.ink2, maxWidth: 370)
            D.text(example.1, 460, y, size: 11.5, color: D.ink2, maxWidth: 540)
            hit(NSRect(x: 64, y: y - 8, width: 936, height: 17), ":\(example.0)，\(example.1)", .draft(example.0))
        }
        let file = model.store.directory.appendingPathComponent("bookmarks.json").path
        D.text("FILES: " + file, 64, 726, size: 10, color: D.muted, maxWidth: 1336)
        hit(NSRect(x: 64, y: 716, width: 1336, height: 20), file)
    }

    private func drawLog() {
        typealias D = TerminalDrawing
        let start = min(max(0, model.bufferOffset), model.logs.count)
        let end = min(model.logs.count, start + 32)
        if model.logs.isEmpty { D.text("日志为空。", 72, 84, size: 12, color: D.muted) }
        for index in start..<end {
            let line = model.logs[index]
            let y = 84 + CGFloat(index - start) * 20
            D.text(String(format: "%03d", index + 1), 72, y, size: 10, color: D.muted)
            D.text(line.time, 116, y, size: 11, color: D.muted, maxWidth: 70)
            D.text(line.text, 190, y, size: 12, color: D.level(line.level), maxWidth: 1210)
            hit(NSRect(x: 72, y: y - 10, width: 1328, height: 20), line.time + " " + line.text)
        }
        bufferPosition(start: start, end: end, count: model.logs.count)
    }

    private func drawCalc() {
        typealias D = TerminalDrawing
        let left: CGFloat = 72
        let right: CGFloat = 1368
        let resultY: CGFloat = 114
        let expression = model.calcExpression.trimmingCharacters(in: .whitespacesAndNewlines)

        if let error = model.calcError {
            D.text("✗ " + error, left, resultY - 6, size: 15, color: D.red, bold: true, maxWidth: right - left)
            hit(NSRect(x: left, y: 84, width: right - left, height: 64), "无法计算：\(error)")
        } else if expression.isEmpty {
            D.text("输入算式后按 Enter 计算", left, resultY - 4, size: 14, color: D.muted)
        } else if let value = try? TerminalCalculator.evaluate(expression) {
            let text = TerminalCalculator.format(value)
            D.text(text, left, resultY, size: 40, color: D.green, bold: true, maxWidth: right - left)
            hit(NSRect(x: left, y: 84, width: right - left, height: 64), "结果 \(text)")
        } else {
            D.text("…", left, resultY, size: 34, color: D.line, bold: true)
        }

        D.rule(left, 168, right - left)
        D.text("HISTORY · \(model.calcHistory.count) 条", left, 192, size: 10.5, color: D.muted)
        D.text("↑↓ 选择 · 点击载入 · c 复制结果", right, 192, size: 10.5, color: D.muted, align: .right)

        let capacity = LauncherModel.calcVisibleRows
        let start = min(max(0, model.bufferOffset), model.calcHistory.count)
        let end = min(model.calcHistory.count, start + capacity)
        guard start < end else { return }
        for index in start..<end {
            let entry = model.calcHistory[index]
            let y = 216 + CGFloat(index - start) * 26
            let selected = model.calcHistoryIndex == index
            if selected {
                D.rect(NSRect(x: left - 8, y: y - 11, width: right - left + 16, height: 22), D.ink)
                D.rect(NSRect(x: left - 8, y: y - 11, width: 3, height: 22), D.yellow)
            }
            D.text(String(format: "%02d", index + 1), left, y, size: 10, color: selected ? D.yellow : D.muted)
            D.text(entry.time, left + 28, y, size: 11, color: selected ? D.mint : D.muted)
            let valueWidth = D.width(entry.value, size: 13, bold: true)
            let expressionWidth = max(80, right - left - 130 - valueWidth - 24)
            D.text(entry.expression, left + 100, y, size: 12.5,
                   color: selected ? D.paper : D.ink, maxWidth: expressionWidth)
            D.text(entry.value, right, y, size: 13, color: selected ? D.mint : D.green,
                   bold: true, align: .right)
            hit(NSRect(x: left - 8, y: y - 11, width: right - left + 16, height: 22),
                "\(entry.expression) = \(entry.value)", .calcRow(index), selected: selected)
        }
        bufferPosition(start: start, end: end, count: model.calcHistory.count)
    }

    private func drawJob() {
        typealias D = TerminalDrawing
        guard let job = model.job else {
            D.text("尚无任务输出。使用 :backup、:restore 或 :import edge 执行数据操作。", 72, 84, size: 12, color: D.muted)
            return
        }
        D.text("TASK", 72, 84, size: 11, color: D.muted)
        D.text(job.title, 150, 84, size: 13, bold: true, maxWidth: 880)
        let label: String
        let background: NSColor
        switch job.status {
        case .running: label = "RUNNING"; background = D.yellow
        case .success: label = "DONE"; background = D.mint
        case .failure: label = "ERROR"; background = D.red
        }
        let x = min(1050, 170 + D.width(job.title, size: 13, bold: true))
        let width = D.width(label, size: 10, bold: true) + 12
        D.rect(NSRect(x: x, y: 75, width: width, height: 18), background)
        D.text(label, x + 6, 84, size: 10, color: job.status == .failure ? D.paper : D.ink, bold: true)
        D.rule(72, 104, 1296)
        let start = min(max(0, model.bufferOffset), job.lines.count)
        let end = min(job.lines.count, start + 25)
        for index in start..<end {
            let line = job.lines[index]
            let y = 132 + CGFloat(index - start) * 24
            D.text(String(format: "%02d", index + 1), 72, y, size: 10, color: D.muted)
            D.text(line.text, 116, y, size: 12.5, color: D.level(line.level), maxWidth: 1252)
            hit(NSRect(x: 72, y: y - 12, width: 1296, height: 24), line.text)
        }
        if job.status == .running, end - start < 24 {
            D.text("▊ 运行中…", 72, 142 + CGFloat(end - start) * 24, size: 12, color: D.amber)
        }
        D.text("命令与真实执行结果同时写入 :log。", 40, 728, size: 10, color: D.muted)
        bufferPosition(start: start, end: end, count: job.lines.count)
    }

    private func bufferPosition(start: Int, end: Int, count: Int) {
        guard start > 0 || end < count else { return }
        TerminalDrawing.text("\(count == 0 ? 0 : start + 1)–\(end) / \(count) · 滚轮滚动", 1400, 728,
                             size: 10, color: TerminalDrawing.muted, align: .right)
    }
}
