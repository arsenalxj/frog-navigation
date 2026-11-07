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
        customDraft?.type == .url ? [.name, .title, .type, .target] : CustomCommandField.allCases
    }
    var customField: CustomCommandField { customFields[min(customFieldIndex, customFields.count - 1)] }
    var customTerminalOptions: [CustomCommandTerminal] {
        (customDraft?.type == .program ? [.none] : []) + installedCustomTerminals
    }

    func refreshCustomTerminals() {
        installedCustomTerminals = CustomCommandExecutor.installedTerminals()
    }

    func customTerminalLabel(_ terminal: CustomCommandTerminal) -> String {
        terminal.label + (terminal != .none && !installedCustomTerminals.contains(terminal) ? "（未安装）" : "")
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
        guard isCustomDirectoryEditing else { return }
        completionTask?.cancel()
        completionGeneration &+= 1
        let generation = completionGeneration
        let text = inputText
        let base = customDirectoryBase
        prompt?.choices = []
        prompt?.selectedChoice = 0
        customDirectoryLoading = true
        completionTask = Task { [weak self] in
            let choices = await Task.detached(priority: .userInitiated) {
                let normalized = ["~", ".", ".."].contains(text) ? text + "/" : text
                return Self.pathChoices(text: normalized, command: "commands-directory", base: base)
            }.value
            guard let self, !Task.isCancelled, completionGeneration == generation,
                  isCustomDirectoryEditing, inputText == text else { return }
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
        customDirectoryBrowsing
            ? "↑↓ 移动 · Tab 选择并进入 · ⇧Tab 上一级 · Enter 退出浏览 · Esc 还原"
            : "↑↓ 切字段 · Enter 浏览目录 · 也可直接输入路径"
    }

    func beginCustomDirectoryBrowse() {
        guard isCustomDirectoryEditing, !customSaving else { return }
        if !customDirectoryBrowsing {
            customDirectoryBrowseOrigin = inputText
            customDirectoryBrowsing = true
        }
        if !inputText.hasSuffix("/"), (try? resolvedCustomDirectory(inputText)) != nil {
            setInput(.prompt, text: inputText + "/")
        }
        prompt?.hint = customDirectoryHint
        prompt?.error = nil
        refreshCustomDirectoryChoices()
    }

    func cancelCustomDirectoryBrowse() {
        guard customDirectoryBrowsing else { return }
        setInput(.prompt, text: customDirectoryBrowseOrigin)
        customDirectoryBrowsing = false
        prompt?.hint = customDirectoryHint
        prompt?.error = nil
        customFeedback = nil
        captureCustomDraft()
        refreshCustomDirectoryChoices()
    }

    func moveCustomDirectoryChoice(_ direction: Int) {
        guard customDirectoryBrowsing, let prompt, !prompt.choices.isEmpty else { return }
        self.prompt?.selectedChoice = (prompt.selectedChoice + direction + prompt.choices.count) % prompt.choices.count
    }

    func openCustomDirectoryChoice() {
        guard customDirectoryBrowsing, let prompt, prompt.choices.indices.contains(prompt.selectedChoice) else { return }
        setInput(.prompt, text: prompt.choices[prompt.selectedChoice].label)
        captureCustomDraft()
        self.prompt?.error = nil
        customFeedback = nil
        refreshCustomDirectoryChoices()
    }

    func ascendCustomDirectory() {
        guard customDirectoryBrowsing else { return }
        let expanded = (inputText as NSString).expandingTildeInPath
        let candidate = expanded.hasPrefix("/") ? expanded : customDirectoryBase.appendingPathComponent(expanded).path
        let standardized = URL(fileURLWithPath: candidate, isDirectory: true).standardizedFileURL.path
        let parent = (standardized as NSString).deletingLastPathComponent
        setInput(.prompt, text: parent == "/" ? "/" : parent + "/")
        customDirectoryPreselectPath = standardized
        captureCustomDraft()
        prompt?.error = nil
        refreshCustomDirectoryChoices()
    }

    func exitCustomDirectoryBrowse() {
        guard customDirectoryBrowsing else { return }
        do { _ = try resolvedCustomDirectory(inputText) }
        catch {
            prompt?.error = error.localizedDescription
            customFeedback = error.localizedDescription
            return
        }
        customDirectoryBrowsing = false
        prompt?.hint = customDirectoryHint
        prompt?.error = nil
        customFeedback = nil
        captureCustomDraft()
        refreshCustomDirectoryChoices()
    }

    func chooseCustomDirectoryCandidate(at index: Int) {
        guard isCustomDirectoryEditing, let prompt, prompt.choices.indices.contains(index) else { return }
        if !customDirectoryBrowsing {
            customDirectoryBrowseOrigin = inputText
            customDirectoryBrowsing = true
            self.prompt?.hint = customDirectoryHint
        }
        self.prompt?.selectedChoice = index
        openCustomDirectoryChoice()
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
        case .list, .delete: return selectedCustomCommand
        }
    }
    var customExecutionRows: [(String, String)] {
        guard let command = customExecutionCommand else { return [] }
        var rows: [(String, String)] = command.type == .url
            ? [("网址模板", command.target), ("查询参数", customExecutionInput)]
            : [("工作目录", command.directory), ("终端", command.terminal.label), ("执行内容", command.target),
               ("参数模板", command.arguments.isEmpty ? "（无）" : command.arguments), ("输入参数", customExecutionInput.isEmpty ? "（无）" : customExecutionInput)]
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
        customScreen = .list
        customFeedback = nil
        clampCustomSelection()
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
        customDirectoryBrowsing = false
        customDirectoryPreselectPath = nil
        let field = customField
        if field == .terminal { refreshCustomTerminals() }
        let hint = field == .directory ? customDirectoryHint
            : field == .terminal ? "已检测 \(installedCustomTerminals.count) 个终端 · ↑↓ 切字段 · ←→ / 空格改值"
            : field.isOption ? "↑↓ 切换字段 · ←→ / 空格改值 · ⌘Enter 保存" : "↑↓ 切换字段 · ⌘Enter 保存 · Esc 取消"
        prompt = TerminalPrompt(command: "commands-edit", field: field.label,
                                hint: hint,
                                acceptsText: !field.isOption)
        setInput(.prompt, text: customValue(field, command: draft))
        if field == .directory {
            if !inputText.hasSuffix("/"), (try? resolvedCustomDirectory(inputText)) != nil { setInput(.prompt, text: inputText + "/") }
            refreshCustomDirectoryChoices()
        }
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
    func cycleCustomOption(_ direction: Int) {
        guard var draft = customDraft else { return }
        if customField == .type {
            let values = CustomCommandKind.allCases
            let index = values.firstIndex(of: draft.type) ?? 0
            draft.type = values[(index + direction + values.count) % values.count]
            if draft.type == .terminal, draft.terminal == .none { draft.terminal = installedCustomTerminals.first ?? .terminal }
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
        do {
            if draft.type != .url { draft.directory = try resolvedCustomDirectory(draft.directory).path }
            let command = try draft.validated(reservedNames: Self.reservedCommandNames)
            var next = customCommands
            if let original = customOriginalName, let index = next.firstIndex(where: { $0.name == original }) { next[index] = command }
            else { next.append(command) }
            persistCustomCommands(next, selecting: command.name, message: "已保存 :\(command.name)")
        } catch { prompt?.error = error.localizedDescription; customFeedback = error.localizedDescription }
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
        guard !customSaving, let command = selectedCustomCommand else { return }
        customScreen = .delete
        customFeedback = nil
        prompt = TerminalPrompt(command: "commands-delete", field: "删除", hint: "y 确认 · n / Enter / Esc 取消", acceptsText: false)
        setInput(.prompt, text: ":\(command.name) · 只删除配置")
    }
    func confirmCustomDelete() {
        guard customScreen == .delete, let command = selectedCustomCommand else { return }
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
        customFeedback = nil
        if inputKind == .command || inputKind == .search { inputKind = nil; return }
        if customScreen != .list {
            finishPrompt()
            customDraft = nil
            customScreen = .list
            bufferOffset = 0
            clampCustomSelection()
        } else if !customQuery.isEmpty { customQuery = ""; customIndex = 0; clampCustomSelection() }
        else { buffer = nil; bufferOffset = 0 }
    }
    func executeCustomCommand(_ command: CustomCommand, input: String = "") {
        guard !customExecuting, !customSaving, customLoaded else {
            commandError(customExecuting ? "已有自定义命令正在执行，请等待该进程结束。" : "自定义命令配置尚未就绪。")
            return
        }
        buffer = .commands
        inputKind = nil
        prompt = nil
        customScreen = .execution
        bufferOffset = 0
        customExecutionCommand = command
        customExecutionInput = input
        customExecutionSummary = "正在启动…"
        customExecutionOutput = []
        customExecutionFailed = false
        customFeedback = nil
        customExecuting = true
        Task { [self] in
            defer { customExecuting = false }
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
        if event.keyCode == 53 {
            if customScreen == .execution, customExecuting {
                customExecutor.cancelRunningProgram()
                customExecutionSummary = "已请求终止后台程序；等待退出状态…"
                return true
            }
            if customScreen == .edit, customDirectoryBrowsing { cancelCustomDirectoryBrowse(); return true }
            escapeCustomCommands(); return true
        }
        if customScreen == .edit {
            if modifiers == .command, [36, 76].contains(event.keyCode) { saveCustomDraft(); return true }
            if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) { return false }
            let browsing = isCustomDirectoryEditing && customDirectoryBrowsing
            if [125, 126].contains(event.keyCode) {
                if browsing { moveCustomDirectoryChoice(event.keyCode == 125 ? 1 : -1) }
                else { moveCustomField(event.keyCode == 125 ? 1 : -1) }
                return true
            }
            if event.keyCode == 48 {
                if browsing {
                    if modifiers.contains(.shift) { ascendCustomDirectory() } else { openCustomDirectoryChoice() }
                }
                else { moveCustomField(modifiers.contains(.shift) ? -1 : 1) }
                return true
            }
            if [36, 76].contains(event.keyCode) {
                if browsing { exitCustomDirectoryBrowse() }
                else if isCustomDirectoryEditing { beginCustomDirectoryBrowse() }
                else if customFieldIndex == customFields.count - 1 { saveCustomDraft() }
                else { moveCustomField(1) }
                return true
            }
            if customField.isOption {
                if text == " " || [123, 124].contains(event.keyCode) { cycleCustomOption(event.keyCode == 123 ? -1 : 1) }
                return true
            }
            // 字符输入由字段编辑器经 updateInput 处理，并会先退出浏览。
            return false
        }
        if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) { return false }
        if customScreen == .delete {
            if text.lowercased() == "y", modifiers.isEmpty || modifiers == .shift { confirmCustomDelete() }
            else if text.lowercased() == "n" || [36, 76].contains(event.keyCode) { escapeCustomCommands() }
            return true
        }
        if inputKind == .search {
            if [36, 76].contains(event.keyCode) { inputKind = nil; return true }
            return false
        }
        if text == ":" { startCommand(); return true }
        if customScreen == .execution {
            if text == "e", let command = customExecutionCommand { beginCustomEdit(command) }
            else if [125, 126, 121, 116].contains(event.keyCode) { scroll(rows: [125, 121].contains(event.keyCode) ? 1 : -1) }
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
        case "a": beginCustomEdit()
        case "e": if let command = selectedCustomCommand { beginCustomEdit(command) }
        case "c": if let command = selectedCustomCommand { beginCustomEdit(command, copy: true) }
        case "D": requestCustomDelete()
        case "/": startCustomSearch()
        case "g": customIndex = 0; clampCustomSelection()
        case "G": customIndex = max(0, filteredCustomCommands.count - 1); clampCustomSelection()
        default: return false
        }
        return true
    }
}
