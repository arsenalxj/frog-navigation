import AppKit
import FrogCore

extension LauncherModel {
    static let commandDirectory: [TerminalCommand] = [
        .init(name: "add", summary: "添加书签", usage: ":add", detail: "URL → title → location；新文件夹与书签一起保存"),
        .init(name: "edit", summary: "编辑所选书签", usage: ":edit [title|url]", detail: "Tab/Shift+Tab 切字段；Enter 一次保存全部；Esc 不保存"),
        .init(name: "rename", summary: "重命名所选文件夹", usage: ":rename", detail: "非空、60 字以内、不能重名"),
        .init(name: "mkdir", summary: "创建文件夹", usage: ":mkdir [名称]", detail: "空参数进入名称提示流"),
        .init(name: "move", summary: "移动所选书签", usage: ":move", detail: "根目录 / 现有文件夹 / 新建文件夹；Enter 前不写入"),
        .init(name: "delete", summary: "删除所选项", usage: ":delete", detail: "y 确认，N/Enter/Esc 取消；只可删除空文件夹"),
        .init(name: "open", summary: "打开书签或文件夹", usage: ":open [行号]", detail: "无参数打开当前项；网址交给系统默认浏览器"),
        .init(name: "copy", summary: "复制所选书签网址", usage: ":copy", detail: "写入系统剪贴板"),
        .init(name: "find", summary: "搜索标题和网址", usage: ":find [关键词]", detail: "上下选择；无结果 Enter 打开网址或 Google 搜索"),
        .init(name: "group", summary: "进入文件夹", usage: ":group 名称", detail: "完整名称或唯一前缀；:group 根目录 返回"),
        .init(name: "backup", summary: "导出 JSON 备份", usage: ":backup [文件路径]", detail: "真实数据快照；支持空格和 ~；不能覆盖当前 bookmarks.json"),
        .init(name: "restore", summary: "从 JSON 整体恢复", usage: ":restore [文件路径]", detail: "Enter 执行校验并整体替换全部书签和文件夹；不合并数据"),
        .init(name: "cd", summary: "切换数据目录", usage: ":cd [目录路径]", detail: "已有 bookmarks.json 直接读取；空目录写入当前数据；旧目录保留"),
        .init(name: "set", summary: "查看或修改本机设置", usage: ":set [login|hotkey|corner|finder|data] [值]", detail: "login on/off/approve · hotkey on/off/reset/record · corner on/off/left-up/left-down/right-up/right-down · finder on/off/authorize/retry · data 路径"),
        .init(name: "retry", summary: "重新读取真实数据文件", usage: ":retry", detail: "修复文件或恢复挂载后重试；读取失败保留已载入数据"),
        .init(name: "clear", summary: "清空本次运行日志", usage: ":clear", detail: "不修改书签或文件"),
        .init(name: "help", summary: "查看命令帮助", usage: ":help", detail: "浏览：j/k/上下 · g/G · PageUp/Down · Enter · / 搜索 · : 命令 · o 整理"),
        .init(name: "log", summary: "查看操作日志", usage: ":log", detail: "仅显示本次运行真实事件，保留最近 200 条"),
        .init(name: "atlas", summary: "可操作的命令地图", usage: ":atlas", detail: "F1 · 上下选择 · Enter 执行 · Esc 返回"),
        .init(name: "q", summary: "退出青蛙导航", usage: ":q", detail: "退出当前应用")
    ]

    func runCommand(_ raw: String) {
        guard prompt == nil, !busy else { return }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == ":" { value.removeFirst() }
        guard !value.isEmpty else { return }
        let split = value.firstIndex(where: \.isWhitespace) ?? value.endIndex
        let name = value[..<split].lowercased()
        let argument = String(value[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
        inputKind = nil
        appendLog(":" + value, .command)
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
            if !argument.isEmpty {
                guard let number = Int(argument), number >= 1, number <= items.count else {
                    commandError("没有第 \(argument) 个可打开项。")
                    return
                }
                selectedIndex = number - 1
                clampSelection()
            }
            buffer = nil
            activateSelection()
        case "copy": copySelection()
        case "find": startSearch(); updateInput(argument)
        case "group":
            if ["根目录", "root", "/"].contains(argument) { buffer = nil; closeFolder(); return }
            guard !argument.isEmpty else { commandError("用法：:group 文件夹名称 / 根目录"); return }
            let exact = document.groups.first { $0.name == argument }
            let matches = document.groups.filter { $0.name.hasPrefix(argument) }
            if let group = exact ?? (matches.count == 1 ? matches.first : nil) { enterFolder(group.id) }
            else { commandError(matches.count > 1 ? "多个文件夹匹配，请输入完整名称。" : "找不到文件夹 “\(argument)”。") }
        case "backup", "restore", "cd":
            beginFilePrompt(name, path: argument.isEmpty ? nil : argument)
            if !argument.isEmpty { submitInput() }
        case "set": runSetting(argument)
        case "help": openBuffer(.help)
        case "log": openBuffer(.log)
        case "atlas": openBuffer(.atlas)
        case "clear":
            logs = []
            if buffer == .log { bufferOffset = 0 }
            rebuildSettings()
        case "retry": retryStorage()
        case "q":
            if let terminateApplication { terminateApplication() }
            else { NSApp?.terminate(nil) }
        default: commandError("未知命令 “\(name)” · 输入 :help 查看命令。")
        }
    }

    func commandError(_ message: String) { appendLog(message, .error) }

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
                else { appendLog("已请求系统\(value == "on" ? "启用" : "停用")登录启动；结果以系统状态为准。", .info) }
            case "approve":
                login.openSettings()
                if let error = login.error { commandError(error) }
                else { appendLog("已打开系统登录项设置；请在系统中批准后返回。", .info) }
            default: commandError("用法：:set login on/off/approve")
            }
        case "hotkey":
            guard let hotKey else { commandError("全局快捷键控制器不可用。"); return }
            switch value {
            case "on", "off": hotKey.setEnabled(value == "on")
            case "reset": hotKey.restoreDefault()
            case "record":
                hotKey.beginRecording()
                guard hotKey.recording else { commandError("全局快捷键控制器尚未启动，无法录入。"); return }
                draft = Draft()
                beginPrompt("hotkey", field: "press keys", value: "", hint: "按下新的组合键 · Esc 取消", acceptsText: false)
            default: commandError("用法：:set hotkey on/off/reset/record"); return
            }
            if let error = hotKey.error { commandError(error) }
            else if value != "record" {
                appendLog("全局快捷键：\(hotKey.configuration.enabled ? hotKey.configuration.shortcut.display : "off")", .info)
            }
        case "corner":
            guard let hotCorner else { commandError("屏幕触角控制器不可用。"); return }
            let corners: [String: ScreenCorner] = ["left-up": .topLeft, "left-down": .bottomLeft,
                                                   "right-up": .topRight, "right-down": .bottomRight]
            if value == "on" || value == "off" { hotCorner.setEnabled(value == "on") }
            else if let corner = corners[value] { hotCorner.setCorner(corner); hotCorner.setEnabled(true) }
            else { commandError("用法：:set corner on/off/left-up/left-down/right-up/right-down"); return }
            flash("corner")
            if let error = hotCorner.error { commandError(error) }
            else { appendLog("屏幕触角：\(hotCorner.configuration.enabled ? hotCorner.configuration.corner.title : "off")", .info) }
        case "finder":
            guard let finderJump else { commandError("Finder 快跳控制器不可用。"); return }
            switch value {
            case "on", "off": finderJump.setEnabled(value == "on")
            case "authorize":
                guard finderJump.enabled else { commandError("请先执行 :set finder on。"); return }
                guard !finderJump.checkingPermissions, !finderJump.requestingPermission else {
                    appendLog("系统权限检查或授权请求正在进行。", .info)
                    return
                }
                if let permission = finderJump.permissions.missing.first {
                    finderJump.requestPermission(permission)
                    appendLog("已请求：\(permission.buttonTitle)；结果以系统状态为准。", .info)
                } else { finderJump.refresh(); appendLog("正在重新检查真实系统权限。", .info) }
            case "retry":
                guard finderJump.enabled else { commandError("请先执行 :set finder on。"); return }
                finderJump.refresh()
            default: commandError("用法：:set finder on/off/authorize/retry"); return
            }
            if let error = finderJump.error { commandError(error) }
        case "data":
            beginFilePrompt("cd", path: originalValue.isEmpty ? nil : originalValue)
            if !originalValue.isEmpty { submitInput() }
        default: commandError("未知设置项 “\(key)” · 可用 login / hotkey / corner / finder / data")
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
            else { appendLog("已重新载入 \(document.bookmarks.count) 条书签与 \(document.groups.count) 个文件夹。", .success) }
            operationActive = false
            busy = store.isBusy
            rebuildItems()
            rebuildSettings()
        }
    }

    func completeCommand(backward: Bool) {
        let candidates: [String]
        if lastCompletedCommand != inputText { commandCompletionPrefix = inputText }
        let prefix = commandCompletionPrefix ?? inputText
        if prefix.hasPrefix("set ") {
            let settings = ["set login on", "set login off", "set login approve", "set hotkey on", "set hotkey off",
                            "set hotkey reset", "set hotkey record", "set corner on", "set corner off", "set corner left-up",
                            "set corner left-down", "set corner right-up", "set corner right-down", "set finder on",
                            "set finder off", "set finder authorize", "set finder retry", "set data "]
            candidates = settings.filter { $0.hasPrefix(prefix) }
        } else { candidates = commands.map(\.name).filter { $0.hasPrefix(prefix) } }
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
            .init(kind: .note, value: "# 本机偏好 · 不随书签同步，不进入备份", level: .muted),
            .init(kind: .blank), .init(kind: .section, key: "[general] · 通用")
        ]
        rows.append(.init(kind: .value, key: "login", value: login.changing ? "changing…" : (login.requiresApproval ? "等待系统批准" : (login.enabled ? "on" : "off")),
                          command: login.requiresApproval ? ":set login approve" : ":set login on/off",
                          level: login.requiresApproval ? .warning : .normal))
        if isolated { rows.append(.init(kind: .note, value: "隔离运行：不允许修改系统登录项。", level: .muted)) }
        if let error = login.error { rows.append(.init(kind: .note, value: error, level: .error)) }
        if let hotKey {
            let state = hotKey.recording ? "recording…" : (hotKey.configuration.enabled ? hotKey.configuration.shortcut.display : "off")
            rows.append(.init(kind: .value, key: "hotkey", value: state, command: ":set hotkey record/reset/on/off"))
            if hotKey.configuration.enabled && !hotKey.registered && !hotKey.recording {
                rows.append(.init(kind: .note, value: "快捷键当前未注册。", command: ":set hotkey on", level: .warning))
            }
            if let error = hotKey.error { rows.append(.init(kind: .note, value: error, level: .error)) }
        } else { rows.append(.init(kind: .value, key: "hotkey", value: "控制器不可用", level: .warning)) }
        if let hotCorner {
            let state = hotCorner.configuration.enabled ? hotCorner.configuration.corner.title : "off"
            rows.append(.init(kind: .value, key: "corner", value: state,
                              command: ":set corner left-up/left-down/right-up/right-down/on/off"))
            if hotCorner.configuration.enabled && !hotCorner.monitoring {
                rows.append(.init(kind: .note, value: "鼠标监听未运行。", command: ":set corner on", level: .warning))
            }
            if let error = hotCorner.error { rows.append(.init(kind: .note, value: error, level: .error)) }
        } else { rows.append(.init(kind: .value, key: "corner", value: "控制器不可用", level: .warning)) }
        if let finderJump {
            rows.append(.init(kind: .value, key: "finder", value: finderJump.enabled ? (finderJump.running ? "on · running" : "on · 等待权限/服务") : "off",
                              command: ":set finder on/off/authorize/retry"))
            if finderJump.checkingPermissions || finderJump.requestingPermission {
                rows.append(.init(kind: .note, value: "正在等待系统权限检查/授权…", level: .info))
            } else if finderJump.enabled {
                if !finderJump.permissions.missing.isEmpty {
                    rows.append(.init(kind: .note, value: finderJump.permissions.missing.map(\.buttonTitle).joined(separator: " · "),
                                      command: ":set finder authorize", level: .warning))
                }
                if finderJump.shortcutConflict {
                    rows.append(.init(kind: .note, value: "⌃G 与启动台全局快捷键冲突；目录入口仍可点击。", command: ":set hotkey record", level: .warning))
                } else if !finderJump.shortcutAvailable {
                    rows.append(.init(kind: .note, value: "⌃G 监听未就绪。", command: ":set finder retry", level: .warning))
                }
            }
            if let error = finderJump.permissions.finderAutomationError { rows.append(.init(kind: .note, value: error, level: .error)) }
            if let error = finderJump.error { rows.append(.init(kind: .note, value: error, level: .error)) }
        } else { rows.append(.init(kind: .value, key: "finder", value: "控制器不可用", level: .warning)) }
        rows += [.init(kind: .blank), .init(kind: .section, key: "[data] · 书签数据"),
                 .init(kind: .value, key: "file", value: store.directory.appendingPathComponent("bookmarks.json").path, command: ":cd <目录>"),
                 .init(kind: .note, value: "# 文件名固定为 bookmarks.json；:cd 切换存放目录。", level: .muted)]
        if let issue = store.issue { rows.append(.init(kind: .note, value: issue, command: ":retry / :cd", level: .error)) }
        rows += [.init(kind: .blank), .init(kind: .section, key: "[operations] · 数据操作"),
                 .init(kind: .action, value: "导出备份 · 另存书签与文件夹 JSON", command: ":backup [文件路径]"),
                 .init(kind: .action, value: "恢复备份 · 替换当前全部书签与文件夹", command: ":restore <备份文件>"),
                 .init(kind: .blank), .init(kind: .section, key: "[status] · 运行状态"),
                 .init(kind: .value, key: "bookmarks", value: String(document.bookmarks.count)),
                 .init(kind: .value, key: "groups", value: String(document.groups.count)),
                 .init(kind: .value, key: "schema", value: "\(document.format) v\(document.schemaVersion)", level: .muted),
                 .init(kind: .value, key: "log", value: "\(logs.count) lines", command: ":log", level: .muted)]
        settingsRows = rows
        if buffer == .settings { bufferOffset = min(bufferOffset, max(0, rows.count - 31)) }
    }
}
