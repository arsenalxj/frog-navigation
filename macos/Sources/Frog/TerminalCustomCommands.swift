import AppKit
import FrogCore

enum CustomCommandScreen { case list, edit, delete, execution }
enum CustomCommandField: CaseIterable {
    case name, title, type, directory, target, arguments, terminal
    var label: String {
        switch self {
        case .name: return "命令名"
        case .title: return "名称"
        case .type: return "动作类型"
        case .directory: return "工作目录"
        case .target: return "执行内容 / 网址"
        case .arguments: return "参数模板"
        case .terminal: return "终端"
        }
    }
    var isOption: Bool { self == .type || self == .terminal }
}

@MainActor
extension LauncherModel {
    static var reservedCommandNames: Set<String> { Set(commandDirectory.map(\.name)).union(["calculator"]) }

    var filteredCustomCommands: [CustomCommand] {
        let filter = customQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else { return customCommands }
        return customCommands.filter { $0.name.localizedCaseInsensitiveContains(filter) || $0.title.localizedCaseInsensitiveContains(filter) }
    }
    var selectedCustomCommand: CustomCommand? {
        let items = filteredCustomCommands
        return items.indices.contains(customIndex) ? items[customIndex] : nil
    }
    var customFields: [CustomCommandField] {
        switch customDraft?.type {
        case .url: [.name, .title, .type, .target]
        case .directory: [.name, .title, .type, .directory, .terminal]
        default: CustomCommandField.allCases
        }
    }
    var customField: CustomCommandField { customFields[min(customFieldIndex, customFields.count - 1)] }
    var customTerminalOptions: [CustomCommandTerminal] {
        (customDraft?.type == .program ? [.none] : []) + installedCustomTerminals + (customDraft?.type == .directory ? [.finder] : [])
    }

    func refreshCustomTerminals() {
        installedCustomTerminals = CustomCommandExecutor.installedTerminals()
    }

    func customTerminalLabel(_ terminal: CustomCommandTerminal) -> String {
        terminal.label + (terminal != .none && terminal != .finder && !installedCustomTerminals.contains(terminal) ? "（未安装）" : "")
    }

    func customFieldLabel(_ field: CustomCommandField, command: CustomCommand) -> String {
        field == .terminal && command.type == .directory ? "打开方式" : field.label
    }

    var isCustomDirectoryEditing: Bool {
        buffer == .commands && customScreen == .edit && customField == .directory && prompt?.command == "commands-edit"
    }

    func resolvedCustomDirectory(_ raw: String) throws -> URL {
        let value = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard !value.isEmpty else { throw CustomCommandError.invalidData("请输入工作目录。") }
        let url = (value.hasPrefix("/") ? URL(fileURLWithPath: value, isDirectory: true)
            : customDirectoryBase.appendingPathComponent(value, isDirectory: true)).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CustomCommandError.invalidData("目录不存在或不是文件夹：\(url.path)")
        }
        return url
    }

    func refreshCustomDirectoryChoices() {
        guard isCustomDirectoryEditing, customDirectoryFocused else { return }
        completionTask?.cancel()
        completionGeneration &+= 1
        let generation = completionGeneration
        let text = customDirectoryPath
        let base = customDirectoryBase
        prompt?.choices = []
        prompt?.selectedChoice = 0
        customDirectoryLoading = true
        completionTask = Task { [weak self] in
            let choices = await Task.detached(priority: .userInitiated) {
                let expanded = (text as NSString).expandingTildeInPath
                let url = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded, isDirectory: true)
                    : base.appendingPathComponent(expanded, isDirectory: true)).standardizedFileURL
                var directory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
                let query = exists ? url.path + "/" : text
                let current = exists ? url : url.deletingLastPathComponent()
                var choices = Self.pathChoices(text: query, command: "commands-directory", base: base)
                if FileManager.default.fileExists(atPath: current.path, isDirectory: &directory), directory.boolValue {
                    choices.insert(TerminalChoice(id: current.path, label: current.path, detail: "current-directory"), at: 0)
                }
                return choices
            }.value
            guard let self, !Task.isCancelled, completionGeneration == generation,
                  isCustomDirectoryEditing, customDirectoryFocused,
                  customDirectoryPath == text else { return }
            prompt?.choices = choices
            if let target = customDirectoryPreselectPath,
               let index = choices.firstIndex(where: { $0.label == target || $0.label == target + "/" }) {
                prompt?.selectedChoice = index
            } else {
                prompt?.selectedChoice = 0
            }
            customDirectoryPreselectPath = nil
            customDirectoryLoading = false
        }
    }

    var customDirectoryHint: String {
        customDirectoryFocused
            ? "↑↓ 选择 · → 进入 / ← 上级 · Enter 采纳并收起 · Tab / ⇧Tab 切字段 · Esc 取消浏览"
            : "Tab / ⇧Tab 切字段 · ⌘↓ 浏览目录 · Enter / ⌘Enter 保存 · Esc 取消并丢弃草稿"
    }

    func focusCustomDirectoryChoices() {
        guard isCustomDirectoryEditing, !customSaving, !customDirectoryFocused else { return }
        captureCustomDraft()
        customDirectoryPath = inputText
        customDirectoryFocused = true
        prompt?.acceptsText = false
        prompt?.hint = customDirectoryHint
        prompt?.error = nil
        refreshCustomDirectoryChoices()
    }

    func leaveCustomDirectoryChoices() {
        guard customDirectoryFocused else { return }
        customDirectoryFocused = false
        customDirectoryPath = ""
        customDirectoryPreselectPath = nil
        prompt?.acceptsText = true
        prompt?.hint = customDirectoryHint
        setInput(.prompt, text: inputText)
        completionGeneration &+= 1
        completionTask?.cancel()
        completionTask = nil
        customDirectoryLoading = false
        prompt?.choices = []
        prompt?.selectedChoice = 0
    }

    func moveCustomDirectoryChoice(_ direction: Int) {
        guard customDirectoryFocused, let prompt, !prompt.choices.isEmpty else { return }
        self.prompt?.selectedChoice = min(max(0, prompt.selectedChoice + direction), prompt.choices.count - 1)
    }

    func openCustomDirectoryChoice() {
        guard customDirectoryFocused, let prompt, prompt.choices.indices.contains(prompt.selectedChoice),
              prompt.choices[prompt.selectedChoice].detail != "current-directory" else { return }
        customDirectoryPath = prompt.choices[prompt.selectedChoice].label
        self.prompt?.error = nil
        refreshCustomDirectoryChoices()
    }

    func ascendCustomDirectory() {
        guard customDirectoryFocused, let current = prompt?.choices.first,
              current.detail == "current-directory" else { return }
        let url = URL(fileURLWithPath: current.label, isDirectory: true).standardizedFileURL
        customDirectoryPath = url.deletingLastPathComponent().path
        customDirectoryPreselectPath = url.path
        prompt?.error = nil
        refreshCustomDirectoryChoices()
    }

    func acceptCustomDirectoryChoice() {
        guard customDirectoryFocused, let prompt, prompt.choices.indices.contains(prompt.selectedChoice) else { return }
        do {
            let path = try resolvedCustomDirectory(prompt.choices[prompt.selectedChoice].label).path
            setInput(.prompt, text: path)
            captureCustomDraft()
            leaveCustomDirectoryChoices()
            self.prompt?.error = nil
            customFeedback = nil
        } catch {
            self.prompt?.error = error.localizedDescription
            customFeedback = error.localizedDescription
        }
    }

    func chooseCustomDirectoryCandidate(at index: Int, activate: Bool = false) {
        guard isCustomDirectoryEditing, customDirectoryFocused, let prompt, prompt.choices.indices.contains(index) else { return }
        self.prompt?.selectedChoice = index
        if activate { acceptCustomDirectoryChoice() }
    }


    var customScreenTitle: String {
        switch customScreen {
        case .list: return "自定义命令"
        case .edit: return customOriginalName == nil ? "新建命令" : "编辑命令"
        case .delete: return "删除确认"
        case .execution: return customExecuting ? "执行中" : "执行结果"
        }
    }
    var customDisplayedCommand: CustomCommand? {
        switch customScreen {
        case .edit: return customDraft
        case .execution: return customExecutionCommand
        case .delete: return customDeleteTarget
        case .list: return selectedCustomCommand
        }
    }
    var customExecutionRows: [(String, String)] {
        guard let command = customExecutionCommand else { return [] }
        var rows: [(String, String)]
        switch command.type {
        case .url:
            rows = [("网址模板", command.target), ("查询参数", customExecutionInput)]
        case .directory:
            rows = [("工作目录", command.directory), ("打开方式", command.terminal.label),
                    ("行为", command.terminal == .finder ? "在 Finder 中打开文件夹" : "进入目录并保持终端可输入")]
        case .terminal, .program:
            rows = [("工作目录", command.directory), ("终端", command.terminal.label), ("执行内容", command.target),
                    ("参数模板", command.arguments.isEmpty ? "（无）" : command.arguments), ("输入参数", customExecutionInput.isEmpty ? "（无）" : customExecutionInput)]
        }
        rows.append(("状态", customExecutionSummary))
        rows.append(contentsOf: customExecutionOutput.enumerated().map { ("输出 \($0.offset + 1)", $0.element) })
        return rows
    }

    func loadCustomCommands() {
        guard !customSaving, prompt == nil else { return }
        customLoadTask?.cancel()
        customLoaded = false
        customLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let commands = try await customStore.load(reservedNames: Self.reservedCommandNames)
                guard !Task.isCancelled else { return }
                customCommands = commands
                customLoaded = true
                customIssue = nil
                customIndex = 0
                if buffer == .commands { bufferOffset = 0 }
            } catch {
                guard !Task.isCancelled else { return }
                customIssue = error.localizedDescription + "；修复后执行 :retry 重新读取。"
                appendLog(customIssue!, .error)
            }
        }
    }

    func openCustomCommands() {
        guard prompt == nil, !busy else { return }
        buffer = .commands
        bufferOffset = 0
        inputKind = nil
        customScreen = customExecuting ? .execution : .list
        customFeedback = nil
        if customScreen == .list { clampCustomSelection() }
    }

    func customValue(_ field: CustomCommandField, command: CustomCommand) -> String {
        switch field {
        case .name: return command.name
        case .title: return command.title
        case .type: return command.type.label
        case .directory: return command.directory
        case .target: return command.target
        case .arguments: return command.arguments
        case .terminal: return customTerminalLabel(command.terminal)
        }
    }
    func captureCustomDraft() {
        guard customScreen == .edit, customDraft != nil else { return }
        switch customField {
        case .name: customDraft?.name = inputText
        case .title: customDraft?.title = inputText
        case .directory: customDraft?.directory = inputText
        case .target: customDraft?.target = inputText
        case .arguments: customDraft?.arguments = inputText
        case .type, .terminal: break
        }
    }
    func beginCustomEdit(_ command: CustomCommand? = nil, copy: Bool = false) {
        guard !busy, !customSaving, customLoaded, customIssue == nil else {
            customFeedback = customIssue ?? "配置尚未载入，暂不能编辑。"
            return
        }
        refreshCustomTerminals()
        customOriginalName = copy ? nil : command?.name
        customDraft = command ?? CustomCommand(directory: NSHomeDirectory())
        let basePath = ((customDraft?.directory ?? NSHomeDirectory()) as NSString).expandingTildeInPath
        customDirectoryBase = basePath.hasPrefix("/") ? URL(fileURLWithPath: basePath, isDirectory: true).standardizedFileURL
            : FileManager.default.homeDirectoryForCurrentUser
        if command == nil, let terminal = installedCustomTerminals.first { customDraft?.terminal = terminal }
        if copy, let command {
            var name = command.name + "-copy"
            var suffix = 2
            while customCommands.contains(where: { $0.name == name }) { name = command.name + "-copy-\(suffix)"; suffix += 1 }
            customDraft?.name = name
        }
        buffer = .commands
        customScreen = .edit
        customFieldIndex = 0
        bufferOffset = 0
        customFeedback = nil
        showCustomField()
    }
    func showCustomField() {
        guard let draft = customDraft else { return }
        completionGeneration &+= 1
        completionTask?.cancel()
        completionTask = nil
        customDirectoryLoading = false
        customDirectoryFocused = false
        customDirectoryPath = ""
        customDirectoryPreselectPath = nil
        let field = customField
        if field == .terminal { refreshCustomTerminals() }
        let hint = field == .directory ? customDirectoryHint
            : field.isOption ? "Tab / ⇧Tab 切字段 · ←→ / 空格改值 · Enter / ⌘Enter 保存 · Esc 取消并丢弃草稿"
            : "Tab / ⇧Tab 切字段 · Enter / ⌘Enter 保存 · Esc 取消并丢弃草稿"
        prompt = TerminalPrompt(command: "commands-edit", field: customFieldLabel(field, command: draft),
                                hint: hint,
                                acceptsText: !field.isOption)
        setInput(.prompt, text: customValue(field, command: draft))
    }
    func selectCustomField(_ index: Int) {
        guard customScreen == .edit, !customSaving, customFields.indices.contains(index) else { return }
        if index == customFieldIndex, customField.isOption { cycleCustomOption(1); return }
        captureCustomDraft()
        customFieldIndex = index
        showCustomField()
    }
    func moveCustomField(_ direction: Int) {
        let next = min(max(0, customFieldIndex + direction), customFields.count - 1)
        guard next != customFieldIndex else { return }
        captureCustomDraft()
        customFieldIndex = next
        showCustomField()
    }
    func tabCustomField(backward: Bool) {
        if customDirectoryFocused { leaveCustomDirectoryChoices() }
        moveCustomField(backward ? -1 : 1)
    }
    func cycleCustomOption(_ direction: Int) {
        guard var draft = customDraft else { return }
        if customField == .type {
            let values = CustomCommandKind.allCases
            let index = values.firstIndex(of: draft.type) ?? 0
            draft.type = values[(index + direction + values.count) % values.count]
            if draft.terminal == .finder && draft.type != .directory {
                draft.terminal = draft.type == .terminal ? installedCustomTerminals.first ?? .terminal : .none
            }
            if (draft.type == .terminal || draft.type == .directory), draft.terminal == .none { draft.terminal = installedCustomTerminals.first ?? .terminal }
            if draft.type == .program { draft.terminal = .none }
        } else if customField == .terminal {
            refreshCustomTerminals()
            let values = customTerminalOptions
            guard !values.isEmpty else { customFeedback = "未检测到受支持终端，请安装 Terminal、iTerm2 或 Ghostty 后重新进入此字段。"; return }
            if let index = values.firstIndex(of: draft.terminal) {
                draft.terminal = values[(index + direction + values.count) % values.count]
            } else { draft.terminal = direction < 0 ? values[values.count - 1] : values[0] }
        } else { return }
        customDraft = draft
        showCustomField()
    }
    func saveCustomDraft() {
        guard customScreen == .edit, !customSaving else { return }
        captureCustomDraft()
        guard var draft = customDraft else { return }
        var invalidField: CustomCommandField = .directory
        do {
            if draft.type != .url { draft.directory = try resolvedCustomDirectory(draft.directory).path }
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let field = customFields.first(where: { customValue($0, command: draft).contains("\0") }) {
                invalidField = field
            } else if name.range(of: "^[a-z][a-z0-9_-]*$", options: .regularExpression) == nil || Self.reservedCommandNames.contains(name) {
                invalidField = .name
            } else if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                invalidField = .title
            } else if draft.type != .directory && (draft.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || draft.type == .url || draft.type == .program && !draft.target.hasPrefix("/") && !draft.target.hasPrefix("~/")) {
                invalidField = .target
            } else {
                invalidField = .terminal
            }
            let command = try draft.validated(reservedNames: Self.reservedCommandNames)
            invalidField = .name
            guard !customCommands.contains(where: { $0.name == command.name && $0.name != customOriginalName }) else {
                throw CustomCommandError.invalidData("命令名已存在，请换一个名称。")
            }
            var next = customCommands
            if let original = customOriginalName, let index = next.firstIndex(where: { $0.name == original }) { next[index] = command }
            else { next.append(command) }
            persistCustomCommands(next, selecting: command.name, message: "已保存 :\(command.name)")
        } catch {
            if let index = customFields.firstIndex(of: invalidField) { customFieldIndex = index }
            showCustomField()
            prompt?.error = error.localizedDescription
            customFeedback = error.localizedDescription
        }
    }
    func persistCustomCommands(_ next: [CustomCommand], selecting name: String?, message: String) {
        guard !customSaving, customLoaded, customIssue == nil else { return }
        customSaving = true
        Task { [self] in
            do {
                try await customStore.save(next, reservedNames: Self.reservedCommandNames)
                customCommands = next
                finishPrompt()
                customDraft = nil
                customScreen = .list
                customQuery = ""
                customIndex = name.flatMap { target in next.firstIndex { $0.name == target } } ?? 0
                customFeedback = message
                clampCustomSelection()
                appendLog(message, .success)
            } catch {
                customFeedback = error.localizedDescription
                prompt?.error = error.localizedDescription
                appendLog(error.localizedDescription, .error)
            }
            customSaving = false
        }
    }
    func requestCustomDelete() {
        guard customScreen == .list, prompt == nil, !customSaving, let command = selectedCustomCommand else { return }
        customDeleteTarget = command
        customScreen = .delete
        customFeedback = nil
        prompt = TerminalPrompt(command: "commands-delete", field: "删除", hint: "y 确认 · n / Enter / Esc 取消", acceptsText: false)
        setInput(.prompt, text: ":\(command.name) · 只删除配置")
    }
    func confirmCustomDelete() {
        guard customScreen == .delete, let command = customDeleteTarget else { return }
        persistCustomCommands(customCommands.filter { $0.name != command.name }, selecting: nil, message: "已删除 :\(command.name)，未删除目标文件。")
    }
    func selectCustomCommand(_ index: Int) {
        guard customScreen == .list, !customSaving, filteredCustomCommands.indices.contains(index) else { return }
        customIndex = index
        inputKind = nil
        clampCustomSelection()
    }
    func clampCustomSelection() {
        let count = filteredCustomCommands.count
        customIndex = min(max(0, customIndex), max(0, count - 1))
        if customIndex < bufferOffset { bufferOffset = customIndex }
        if customIndex >= bufferOffset + Self.calcVisibleRows { bufferOffset = customIndex - Self.calcVisibleRows + 1 }
        bufferOffset = min(max(0, bufferOffset), max(0, count - Self.calcVisibleRows))
    }
    func startCustomSearch() {
        guard customScreen == .list, prompt == nil else { return }
        setInput(.search, text: customQuery)
    }
    func escapeCustomCommands() {
        guard !customSaving else { return }
        if customStopConfirmation { cancelCustomStop(); return }
        if customDirectoryFocused { leaveCustomDirectoryChoices(); return }
        customFeedback = nil
        if inputKind == .command { inputKind = nil; return }
        if inputKind == .search || customScreen == .list && !customQuery.isEmpty {
            inputKind = nil
            customQuery = ""
            inputText = ""
            customIndex = 0
            bufferOffset = 0
            clampCustomSelection()
            return
        }
        if customScreen != .list {
            finishPrompt()
            customDraft = nil
            customScreen = .list
            bufferOffset = 0
            clampCustomSelection()
        } else { buffer = nil; bufferOffset = 0 }
    }
    var canStopCustomExecution: Bool {
        customExecuting && customExecutionCommand?.type == .program && customExecutionCommand?.terminal == CustomCommandTerminal.none
    }
    func requestCustomStop() {
        guard buffer == .commands, [.list, .execution].contains(customScreen), prompt == nil,
              inputKind == nil, canStopCustomExecution else { return }
        customStopConfirmation = true
    }
    func cancelCustomStop() { customStopConfirmation = false }
    func confirmCustomStop() {
        guard customStopConfirmation else { return }
        customStopConfirmation = false
        guard canStopCustomExecution else { return }
        customExecutor.cancelRunningProgram()
        customExecutionSummary = "已请求停止后台程序；等待实际退出状态…"
    }
    func showCustomExecution() {
        guard customExecutionCommand != nil, prompt == nil, !customStopConfirmation else { return }
        inputKind = nil
        customScreen = .execution
        bufferOffset = 0
    }
    var customKeyboardHint: String {
        if customStopConfirmation { return "停止当前后台任务？y 确认 · n / Enter / Esc 取消" }
        if inputKind == .command { return "↑↓ 选择命令 · Tab / ⇧Tab 补全 · ⌥↑↓ 历史 · Enter 执行 · Esc 返回" }
        switch customScreen {
        case .edit:
            return isCustomDirectoryEditing ? customDirectoryHint
                : customField.isOption ? "Tab / ⇧Tab 切字段 · ←→ / 空格改值 · Enter / ⌘Enter 保存 · Esc 取消并丢弃草稿"
                : "Tab / ⇧Tab 切字段 · Enter / ⌘Enter 保存 · Esc 取消并丢弃草稿"
        case .delete: return "y 确认删除 · n / Enter / Esc 取消（只删除命令配置）"
        case .execution: return "↑↓ 滚动 · Page Up/Down 翻屏 · e 编辑 · Esc 返回列表" + (canStopCustomExecution ? " · ⌘. 停止任务" : "")
        case .list:
            if inputKind == .search {
                return selectedCustomCommand == nil ? "输入筛选命令 · Esc 清空搜索"
                    : "↑↓ 选择并保留输入 · Tab 进入列表 · Enter 运行 · Esc 清空搜索"
            }
            let actions = selectedCustomCommand == nil ? "/ / ⇧Tab 搜索 · a / ⌘N 新建"
                : "↑↓ 选择 · ⇧Tab 搜索 · Enter 运行 · a / ⌘N 新建 · e 编辑 · ⌘C 复制调用 · ⌘D 创建副本 · ⇧D 删除"
            return actions + (canStopCustomExecution ? " · ⌘. 停止任务" : "")
        }
    }
    func executeCustomCommand(_ command: CustomCommand, input: String = "") {
        guard !customExecuting, !customSaving, customLoaded else {
            commandError(customExecuting ? "已有自定义命令正在执行，请等待该进程结束。" : "自定义命令配置尚未就绪。")
            return
        }
        inputKind = nil
        prompt = nil
        if buffer == .commands {
            customScreen = .execution
            bufferOffset = 0
        }
        customExecutionCommand = command
        customExecutionInput = input
        customExecutionSummary = "正在启动…"
        customExecutionOutput = []
        customExecutionFailed = false
        customFeedback = nil
        customExecuting = true
        Task { [self] in
            defer { customExecuting = false; customStopConfirmation = false }
            do {
                let result = try await customExecutor.execute(command, input: input)
                customExecutionSummary = result.summary
                customExecutionFailed = result.exitCode.map { $0 != 0 } ?? false
                customExecutionOutput = result.output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                appendLog(":\(command.name) · \(result.summary)", customExecutionFailed ? .error : .success)
                for line in customExecutionOutput.suffix(150) { appendLog(line, .normal) }
            } catch {
                customExecutionFailed = true
                customExecutionSummary = error.localizedDescription
                appendLog(error.localizedDescription, .error)
            }
        }
    }
    func handleCustomCommandKey(_ event: NSEvent, isTextEditing: Bool) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let text = event.charactersIgnoringModifiers ?? ""
        if customSaving { return true }
        if customStopConfirmation {
            if modifiers == .command, ["q", "h"].contains(text.lowercased()) { return false }
            if modifiers.isEmpty {
                if text == "y" { confirmCustomStop() }
                else if text == "n" || [36, 76, 53].contains(event.keyCode) { cancelCustomStop() }
            }
            return true
        }
        if modifiers.isEmpty, event.keyCode == 53 { escapeCustomCommands(); return true }
        if modifiers == .command, text == ".", inputKind == nil,
           [.list, .execution].contains(customScreen), canStopCustomExecution { requestCustomStop(); return true }
        if customScreen == .edit {
            if modifiers == .command, [36, 76].contains(event.keyCode) { saveCustomDraft(); return true }
            if modifiers == .command, event.keyCode == 125, isCustomDirectoryEditing {
                focusCustomDirectoryChoices(); return true
            }
            if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift {
                tabCustomField(backward: modifiers == .shift); return true
            }
            guard modifiers.isEmpty else { return false }
            if [36, 76].contains(event.keyCode) {
                if customDirectoryFocused { acceptCustomDirectoryChoice() } else { saveCustomDraft() }
                return true
            }
            if customDirectoryFocused {
                switch event.keyCode {
                case 125: moveCustomDirectoryChoice(1)
                case 126: moveCustomDirectoryChoice(-1)
                case 121: moveCustomDirectoryChoice(10)
                case 116: moveCustomDirectoryChoice(-10)
                case 124: openCustomDirectoryChoice()
                case 123: ascendCustomDirectory()
                default: break
                }
                return true
            }
            if customField.isOption {
                if text == " " || [123, 124].contains(event.keyCode) { cycleCustomOption(event.keyCode == 123 ? -1 : 1) }
                return true
            }
            return false
        }
        if customScreen == .delete {
            guard modifiers.isEmpty else { return false }
            if text == "y" { confirmCustomDelete() }
            else if text == "n" || [36, 76].contains(event.keyCode) { escapeCustomCommands() }
            return true
        }
        if inputKind == .search {
            guard modifiers.isEmpty else { return false }
            switch event.keyCode {
            case 125: customIndex += 1; clampCustomSelection()
            case 126: customIndex -= 1; clampCustomSelection()
            case 121: customIndex += Self.calcVisibleRows; clampCustomSelection()
            case 116: customIndex -= Self.calcVisibleRows; clampCustomSelection()
            case 48: if selectedCustomCommand != nil { inputKind = nil }
            case 36, 76: if let command = selectedCustomCommand { executeCustomCommand(command) }
            default: return false
            }
            return true
        }
        if customScreen == .list, inputKind == nil {
            if modifiers == .command, text.lowercased() == "d" {
                duplicateCurrentCommand()
                return true
            }
            if modifiers == .command, text.lowercased() == "n" { addCurrentObject(); return true }
            if modifiers == .shift, event.keyCode == 48 { startCustomSearch(); return true }
            if modifiers == .shift, text == "D" { requestCustomDelete(); return true }
            if modifiers == .shift, text == "G" { customIndex = max(0, filteredCustomCommands.count - 1); clampCustomSelection(); return true }
        }
        if text == ":", modifiers.isEmpty || modifiers == .shift { startCommand(); return true }
        guard modifiers.isEmpty, !isTextEditing else { return false }
        if customScreen == .execution {
            if text == "e", let command = customExecutionCommand { beginCustomEdit(command) }
            else if [125, 126, 121, 116].contains(event.keyCode) {
                let step = [121, 116].contains(event.keyCode) ? Self.calcVisibleRows : 1
                scroll(rows: [125, 121].contains(event.keyCode) ? step : -step)
            } else { return false }
            return true
        }
        switch event.keyCode {
        case 125: customIndex += 1; clampCustomSelection(); return true
        case 126: customIndex -= 1; clampCustomSelection(); return true
        case 121: customIndex += Self.calcVisibleRows; clampCustomSelection(); return true
        case 116: customIndex -= Self.calcVisibleRows; clampCustomSelection(); return true
        case 36, 76: if let command = selectedCustomCommand { executeCustomCommand(command) }; return true
        default: break
        }
        switch text {
        case "j": customIndex += 1; clampCustomSelection()
        case "k": customIndex -= 1; clampCustomSelection()
        case "a": addCurrentObject()
        case "e": if let command = selectedCustomCommand { beginCustomEdit(command) }
        case "/": startCustomSearch()
        case "g": customIndex = 0; clampCustomSelection()
        default: return false
        }
        return true
    }
}
