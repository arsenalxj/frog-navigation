import AppKit
import FrogCore

extension LauncherModel {
    static let commandDirectory: [TerminalCommand] = [
        .init(name: "add", summary: "添加书签", usage: ":add", detail: "Enter 推进，Tab 切字段，⌘Enter 保存"),
        .init(name: "edit", summary: "编辑书签", usage: ":edit [title|url]", detail: "Tab 切字段，Enter 保存，Esc 放弃修改"),
        .init(name: "rename", summary: "重命名文件夹", usage: ":rename", detail: "非空、60 字内、不重名"),
        .init(name: "mkdir", summary: "新建文件夹", usage: ":mkdir [名称]", detail: "可直接传入文件夹名称"),
        .init(name: "move", summary: "移动书签", usage: ":move", detail: "移至根目录、现有或新建文件夹"),
        .init(name: "delete", summary: "删除所选项", usage: ":delete", detail: "按 y 确认，仅可删除空文件夹"),
        .init(name: "open", summary: "打开所选项", usage: ":open", detail: "打开书签或展开 / 折叠文件夹"),
        .init(name: "copy", summary: "复制当前项", usage: ":copy", detail: "复制网址、命令或计算结果"),
        .init(name: "find", summary: "搜索书签", usage: ":find [关键词]", detail: "匹配标题与网址；无结果可打开网址或搜索"),
        .init(name: "calc", summary: "打开计算器", usage: ":calc [clear]", detail: "Enter 计算，Tab 历史，⌘C 复制结果"),
        .init(name: "commands", summary: "管理自定义命令", usage: ":commands", detail: "终端 / 程序 / 网址 / 打开目录"),
        .init(name: "group", summary: "定位文件夹", usage: ":group 名称", detail: "展开并选中；:group 根目录 折叠全部"),
        .init(name: "backup", summary: "导出 JSON 备份", usage: ":backup [路径]", detail: "另存完整副本，不可覆盖当前数据文件"),
        .init(name: "restore", summary: "恢复 JSON 备份", usage: ":restore [路径]", detail: "校验后整体替换全部书签与文件夹，不合并"),
        .init(name: "import", summary: "导入 Edge 书签", usage: ":import edge [目录]", detail: "只读导入，同名文件夹合并，按网址去重"),
        .init(name: "cd", summary: "切换数据目录", usage: ":cd [目录]", detail: "读取已有数据；空目录写入当前数据"),
        .init(name: "set", summary: "本机设置", usage: ":set [项] [值]", detail: "login / hotkey / corner / finder / data"),
        .init(name: "retry", summary: "重新读取数据", usage: ":retry", detail: "失败时保留已载入内容"),
        .init(name: "clear", summary: "清空日志", usage: ":clear", detail: "仅清空本次运行日志"),
        .init(name: "help", summary: "命令帮助", usage: ":help", detail: "查看命令与快捷键"),
        .init(name: "log", summary: "运行日志", usage: ":log", detail: "最近 200 条操作记录"),
        .init(name: "q", summary: "退出应用", usage: ":q", detail: "完全退出青蛙导航")
    ]

    func runCommand(_ raw: String) {
        guard prompt == nil, !busy else { return }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == ":" { value.removeFirst() }
        guard !value.isEmpty else { return }
        bufferFeedback = nil
        let split = value.firstIndex(where: \.isWhitespace) ?? value.endIndex
        let name = value[..<split].lowercased()
        let argument = String(value[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
        inputKind = nil
        appendLog(":" + value, .command)
        defer { restoreCalcInputIfNeeded() }
        if buffer != nil, ["add", "edit", "rename", "mkdir", "move", "delete", "open"].contains(name) {
            commandError(":\(name) 仅在主界面可用")
            return
        }
        switch name {
        case "add": addBookmark()
        case "edit":
            guard argument.isEmpty || ["title", "url"].contains(argument) else { commandError("用法：:edit [title|url]"); return }
            beginEdit(urlFirst: argument == "url")
        case "rename": beginRename()
        case "mkdir":
            beginMkdir()
            if !argument.isEmpty { updateInput(argument); submitInput() }
        case "move": beginMove()
        case "delete": requestDeleteSelection()
        case "open":
            guard argument.isEmpty else {
                commandError("用法：:open（不接受参数）")
                return
            }
            activateSelection()
        case "copy": copyCurrentObject()
        case "find": startSearch(); updateInput(argument)
        case "group":
            if ["根目录", "root", "/"].contains(argument) {
                bufferOrigin = nil
                buffer = nil
                query = ""
                scrollIndex = 0
                let keep = selectedGroupID()
                expandedGroupIDs = []
                persistExpanded()
                rebuildItems(selecting: keep)
                appendLog("已折叠全部文件夹", .info)
                return
            }
            guard !argument.isEmpty else { commandError("用法：:group 文件夹名称 / 根目录"); return }
            let exact = document.groups.first { $0.name == argument }
            let matches = document.groups.filter { $0.name.hasPrefix(argument) }
            if let group = exact ?? (matches.count == 1 ? matches.first : nil) {
                bufferOrigin = nil
                buffer = nil
                query = ""
                scrollIndex = 0
                expandedGroupIDs.insert(group.id)
                persistExpanded()
                rebuildItems(selecting: group.id)
                appendLog("已定位文件夹“\(group.name)”", .info)
            }
            else { commandError(matches.count > 1 ? "匹配到多个文件夹，请输入完整名称" : "未找到文件夹“\(argument)”") }
        case "backup", "restore", "cd":
            beginFilePrompt(name, path: argument.isEmpty ? nil : argument)
            if !argument.isEmpty { submitInput() }
        case "import":
            let split = argument.firstIndex(where: \.isWhitespace) ?? argument.endIndex
            let source = argument[..<split].lowercased()
            let path = String(argument[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard source == "edge" else {
                commandError("用法：:import edge [数据目录]")
                return
            }
            beginEdgeImport(path: path.isEmpty ? nil : path)
        case "calc", "calculator":
            if argument.isEmpty { openBuffer(.calc) }
            else if argument.lowercased() == "clear" {
                clearCalc()
                if buffer == .calc { setCalcFeedback("✓ 已清空", .success) }
                appendLog("已清空计算器", .success)
            } else { commandError("用法：:calc 打开，:calc clear 清空") }
        case "set": runSetting(argument)
        case "commands":
            guard argument.isEmpty else { commandError("用法：:commands"); return }
            openBuffer(.commands)
        case "help": openBuffer(.help)
        case "log": openBuffer(.log)
        case "clear":
            logs = []
            if buffer == .log { bufferOffset = 0 }
            rebuildSettings()
        case "retry": retryStorage(); loadCustomCommands()
        case "q":
            if let terminateApplication { terminateApplication() }
            else { NSApp?.terminate(nil) }
        default:
            if let command = customCommands.first(where: { $0.name == name }) { executeCustomCommand(command, input: argument) }
            else { commandError("未知命令“\(name)”，输入 :help 查看") }
        }
    }

    func commandError(_ message: String) {
        appendLog(message, .error)
        if buffer == .calc, prompt == nil { setCalcFeedback("✗ " + message, .error) }
        if buffer == .commands { customFeedback = message }
        if let buffer, [.settings, .help, .log, .job].contains(buffer) { bufferFeedback = message }
    }

    func runSetting(_ argument: String) {
        guard !argument.isEmpty else { openSettings(); return }
        let split = argument.firstIndex(where: \.isWhitespace) ?? argument.endIndex
        let key = argument[..<split].lowercased()
        let originalValue = String(argument[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = originalValue.lowercased()
        switch key {
        case "login":
            switch value {
            case "on", "off":
                login.setEnabled(value == "on")
                if let error = login.error { commandError(error) }
                else { appendLog(value == "on" ? "已请求启用登录启动" : "已请求停用登录启动", .info) }
            case "approve":
                login.openSettings()
                if let error = login.error { commandError(error) }
                else { appendLog("已打开系统登录项设置", .info) }
            default: commandError("用法：:set login on/off/approve")
            }
        case "hotkey":
            guard let hotKey else { commandError("全局快捷键不可用"); return }
            switch value {
            case "on", "off": hotKey.setEnabled(value == "on")
            case "reset": hotKey.restoreDefault()
            case "record":
                hotKey.beginRecording()
                guard hotKey.recording else { commandError("快捷键服务未启动，无法录入"); return }
                draft = Draft()
                beginPrompt("hotkey", field: "press keys", value: "", hint: "按下组合键 · Esc 取消", acceptsText: false)
            default: commandError("用法：:set hotkey on/off/reset/record"); return
            }
            if let error = hotKey.error { commandError(error) }
            else if value != "record" {
                appendLog("全局快捷键：\(hotKey.configuration.enabled ? hotKey.configuration.shortcut.display : "已关闭")", .info)
            }
        case "corner":
            guard let hotCorner else { commandError("屏幕触角不可用"); return }
            let corners: [String: ScreenCorner] = ["left-up": .topLeft, "left-down": .bottomLeft,
                                                   "right-up": .topRight, "right-down": .bottomRight]
            if value == "on" || value == "off" { hotCorner.setEnabled(value == "on") }
            else if let corner = corners[value] { hotCorner.setCorner(corner); hotCorner.setEnabled(true) }
            else { commandError("用法：:set corner on/off/left-up/left-down/right-up/right-down"); return }
            flash("corner")
            if let error = hotCorner.error { commandError(error) }
            else { appendLog("屏幕触角：\(hotCorner.configuration.enabled ? hotCorner.configuration.corner.displayName : "已关闭")", .info) }
        case "finder":
            guard let finderJump else { commandError("Finder 快跳不可用"); return }
            switch value {
            case "on", "off": finderJump.setEnabled(value == "on")
            case "authorize":
                guard finderJump.enabled else { commandError("请先执行 :set finder on"); return }
                guard !finderJump.checkingPermissions, !finderJump.requestingPermission else {
                    appendLog("正在检查或请求系统权限", .info)
                    return
                }
                if let permission = finderJump.permissions.missing.first {
                    finderJump.requestPermission(permission)
                    appendLog("已请求\(permission.shortTitle)权限", .info)
                } else { finderJump.refresh(); appendLog("正在检查系统权限…", .info) }
            case "retry":
                guard finderJump.enabled else { commandError("请先执行 :set finder on"); return }
                finderJump.refresh()
            default: commandError("用法：:set finder on/off/authorize/retry"); return
            }
            if let error = finderJump.error { commandError(error) }
        case "data":
            beginFilePrompt("cd", path: originalValue.isEmpty ? nil : originalValue)
            if !originalValue.isEmpty { submitInput() }
        default: commandError("未知设置项“\(key)”，可用 login / hotkey / corner / finder / data")
        }
        rebuildSettings()
    }

    func retryStorage() {
        guard !busy else { return }
        operationActive = true
        busy = true
        Task { [self] in
            await store.load()
            if let issue = store.issue { appendLog(issue, .error) }
            else { appendLog("已载入 \(document.bookmarks.count) 条书签，\(document.groups.count) 个文件夹", .success) }
            operationActive = false
            busy = store.isBusy
            rebuildItems()
            rebuildSettings()
            restoreCalcInputIfNeeded()
        }
    }

    var commandCandidates: [TerminalCommand] {
        guard inputKind == .command, !inputText.contains(where: \.isWhitespace) else { return [] }
        let query = inputText.lowercased()
        return commands.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query) }
    }

    func moveCommandCandidate(_ direction: Int) {
        guard !commandCandidates.isEmpty else { return }
        commandCandidateIndex = min(max(0, (commandCandidateIndex ?? -1) + direction), commandCandidates.count - 1)
    }

    func completeCommand(backward: Bool) {
        if let index = commandCandidateIndex, commandCandidates.indices.contains(index) {
            let name = commandCandidates[index].name
            commandCandidateIndex = nil
            setInput(.command, text: name)
            return
        }
        let candidates: [String]
        if lastCompletedCommand != inputText { commandCompletionPrefix = inputText }
        let prefix = commandCompletionPrefix ?? inputText
        if prefix.hasPrefix("set ") {
            let settings = ["set login on", "set login off", "set login approve", "set hotkey on", "set hotkey off",
                            "set hotkey reset", "set hotkey record", "set corner on", "set corner off", "set corner left-up",
                            "set corner left-down", "set corner right-up", "set corner right-down", "set finder on",
                            "set finder off", "set finder authorize", "set finder retry", "set data "]
            candidates = settings.filter { $0.hasPrefix(prefix) }
        } else { candidates = commands.filter { $0.name.localizedCaseInsensitiveContains(prefix) || $0.summary.localizedCaseInsensitiveContains(prefix) }.map(\.name) }
        guard !candidates.isEmpty else { return }
        let index: Int
        if let lastCompletedCommand, let previous = candidates.firstIndex(of: lastCompletedCommand) {
            index = (previous + (backward ? -1 : 1) + candidates.count) % candidates.count
        } else { index = backward ? candidates.count - 1 : 0 }
        let match = candidates[index]
        lastCompletedCommand = match
        setInput(.command, text: match)
    }

    func recallHistory(_ direction: Int) {
        guard !history.isEmpty else { return }
        if historyIndex == nil { historyDraft = inputText }
        let current = historyIndex ?? history.count
        let next = min(max(0, current + direction), history.count)
        historyIndex = next == history.count ? nil : next
        setInput(.command, text: next == history.count ? historyDraft : history[next])
    }

    func flash(_ key: String) {
        flashTask?.cancel()
        flashSetting = key
        flashTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(900)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.flashSetting = nil
        }
    }

    func rebuildSettings() {
        var rows: [TerminalSettingRow] = [
            .init(kind: .note, value: "# 本机偏好 · 不同步，不进入备份", level: .muted),
            .init(kind: .blank), .init(kind: .section, key: "[general] · 通用")
        ]
        rows.append(.init(kind: .value, key: "login", value: login.changing ? "切换中…" : (login.requiresApproval ? "待系统批准" : (login.enabled ? "已开启" : "已关闭")),
                          command: login.requiresApproval ? ":set login approve" : ":set login on/off",
                          level: login.requiresApproval ? .warning : .normal))
        if isolated { rows.append(.init(kind: .note, value: "隔离模式不可修改系统登录项", level: .muted)) }
        if let error = login.error { rows.append(.init(kind: .note, value: error, level: .error)) }
        if let hotKey {
            let state = hotKey.recording ? "录入中…" : (hotKey.configuration.enabled ? hotKey.configuration.shortcut.display : "已关闭")
            rows.append(.init(kind: .value, key: "hotkey", value: state, command: ":set hotkey record/reset/on/off"))
            if hotKey.configuration.enabled && !hotKey.registered && !hotKey.recording {
                rows.append(.init(kind: .note, value: "快捷键未注册", command: ":set hotkey on", level: .warning))
            }
            if let error = hotKey.error { rows.append(.init(kind: .note, value: error, level: .error)) }
        } else { rows.append(.init(kind: .value, key: "hotkey", value: "不可用", level: .warning)) }
        if let hotCorner {
            let state = hotCorner.configuration.enabled ? hotCorner.configuration.corner.displayName : "已关闭"
            rows.append(.init(kind: .value, key: "corner", value: state,
                              command: ":set corner left-up/left-down/right-up/right-down/on/off"))
            if hotCorner.configuration.enabled && !hotCorner.monitoring {
                rows.append(.init(kind: .note, value: "鼠标监听未运行", command: ":set corner on", level: .warning))
            }
            if let error = hotCorner.error { rows.append(.init(kind: .note, value: error, level: .error)) }
        } else { rows.append(.init(kind: .value, key: "corner", value: "不可用", level: .warning)) }
        if let finderJump {
            rows.append(.init(kind: .value, key: "finder", value: finderJump.enabled ? (finderJump.running ? "运行中" : "待授权") : "已关闭",
                              command: ":set finder on/off/authorize/retry"))
            if finderJump.checkingPermissions || finderJump.requestingPermission {
                rows.append(.init(kind: .note, value: "正在检查权限…", level: .info))
            } else if finderJump.enabled {
                if !finderJump.permissions.missing.isEmpty {
                    rows.append(.init(kind: .note, value: finderJump.permissions.missing.map(\.buttonTitle).joined(separator: " · "),
                                      command: ":set finder authorize", level: .warning))
                }
                if finderJump.shortcutConflict {
                    rows.append(.init(kind: .note, value: "⌃G 与启动台快捷键冲突，浮条仍可点击", command: ":set hotkey record", level: .warning))
                } else if !finderJump.shortcutAvailable {
                    rows.append(.init(kind: .note, value: "⌃G 监听未就绪", command: ":set finder retry", level: .warning))
                }
            }
            if let error = finderJump.permissions.finderAutomationError { rows.append(.init(kind: .note, value: error, level: .error)) }
            if let error = finderJump.error { rows.append(.init(kind: .note, value: error, level: .error)) }
        } else { rows.append(.init(kind: .value, key: "finder", value: "不可用", level: .warning)) }
        rows += [.init(kind: .blank), .init(kind: .section, key: "[data] · 书签数据"),
                 .init(kind: .value, key: "file", value: store.directory.appendingPathComponent("bookmarks.json").path, command: ":cd <目录>"),
                 .init(kind: .note, value: "# 固定读取目录内的 bookmarks.json", level: .muted)]
        if let issue = store.issue { rows.append(.init(kind: .note, value: issue, command: ":retry", level: .error)) }
        rows += [.init(kind: .blank), .init(kind: .section, key: "[operations] · 数据操作"),
                 .init(kind: .action, value: "导出备份 · 另存 JSON 副本", command: ":backup [路径]"),
                 .init(kind: .action, value: "恢复备份 · 整体替换当前书签与文件夹", command: ":restore <文件>"),
                 .init(kind: .action, value: "导入 Edge 书签 · 合并收藏并按网址去重", command: ":import edge"),
                 .init(kind: .action, value: "自定义命令 · 终端 / 程序 / 网址 / 目录", command: ":commands"),
                 .init(kind: .blank), .init(kind: .section, key: "[status] · 运行状态"),
                 .init(kind: .value, key: "bookmarks", value: String(document.bookmarks.count)),
                 .init(kind: .value, key: "groups", value: String(document.groups.count)),
                 .init(kind: .value, key: "schema", value: "\(document.format) v\(document.schemaVersion)", level: .muted),
                 .init(kind: .value, key: "log", value: "\(logs.count) 条", command: ":log", level: .muted)]
        settingsRows = rows
        if buffer == .settings { bufferOffset = min(bufferOffset, max(0, rows.count - 31)) }
    }
}
