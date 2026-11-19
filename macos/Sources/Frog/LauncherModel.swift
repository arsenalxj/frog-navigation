import AppKit
import Combine
import FrogCore

@MainActor
final class LauncherModel: ObservableObject {
    let store: BookmarkStore
    let isolated: Bool
    let login: LoginItemController
    let hotKey: GlobalHotKeyController?
    let hotCorner: HotCornerController?
    let finderJump: FinderJumpController?

    @Published var visible = false
    @Published var presented = false
    @Published var items: [TerminalItem] = []
    @Published var selectedIndex = 0
    @Published var scrollIndex = 0
    @Published var expandedGroupIDs: Set<String> = []
    @Published var query = ""
    @Published var buffer: TerminalBuffer?
    @Published var bufferOffset = 0
    @Published var bufferFeedback: String?
    @Published var inputKind: TerminalInputKind?
    @Published var inputText = ""
    @Published var inputRevision = 0
    @Published var prompt: TerminalPrompt?
    @Published var isOrganizing = false
    @Published var busy = false
    @Published var logs: [TerminalLogEntry] = []
    @Published var job: TerminalJob?
    @Published var settingsRows: [TerminalSettingRow] = []
    @Published var flashSetting: String?
    @Published var calcExpression = ""
    @Published var calcHistory: [TerminalCalcEntry] = []
    @Published var calcHistoryIndex: Int?
    @Published var calcHistoryFocused = false
    @Published var calcError: String?
    @Published var calcFeedback: String?
    @Published var calcFeedbackLevel: TerminalLevel = .success
    @Published var customCommands: [CustomCommand] = []
    @Published var customLoaded = false
    @Published var customIssue: String?
    @Published var customFeedback: String?
    @Published var customScreen: CustomCommandScreen = .list
    @Published var customIndex = 0
    @Published var customQuery = ""
    @Published var customDraft: CustomCommand?
    @Published var customDeleteTarget: CustomCommand?
    @Published var customFieldIndex = 0
    @Published var customSaving = false
    @Published var customExecuting = false
    @Published var customStopConfirmation = false
    @Published var installedCustomTerminals: [CustomCommandTerminal] = []
    @Published var customDirectoryLoading = false
    @Published var customDirectoryFocused = false
    @Published var customDirectoryPath = ""
    var customDirectoryBase = FileManager.default.homeDirectoryForCurrentUser
    var customDirectoryPreselectPath: String?
    @Published var customExecutionCommand: CustomCommand?
    @Published var customExecutionInput = ""
    @Published var customExecutionSummary = ""
    @Published var customExecutionOutput: [String] = []
    @Published var customExecutionFailed = false
    @Published var commandCandidateIndex: Int?
    let customStore: CustomCommandStore
    let customExecutor = CustomCommandExecutor()
    var customLoadTask: Task<Void, Never>?
    var customOriginalName: String?
    var commands: [TerminalCommand] {
        Self.commandDirectory + customCommands.map {
            TerminalCommand(name: $0.name, summary: $0.title, usage: ":" + $0.name,
                            detail: $0.type.label + " · " + ($0.type == .url ? $0.target : $0.directory))
        }
    }

    var dismissWindow: (() -> Void)?
    var terminateApplication: (() -> Void)?
    var readClipboardString: () -> String? = { NSPasteboard.general.string(forType: .string) }
    var document: BookmarkDocument { store.document }
    var visibleRowCount: Int { 19 }
    enum SearchAction {
        case finish, openSelection, openURL, webSearch

        var title: String {
            switch self {
            case .finish: return "结束搜索"
            case .openSelection: return "打开"
            case .openURL: return "打开网址"
            case .webSearch: return "Google 搜索"
            }
        }
    }

    var searchAction: SearchAction {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .finish }
        if !items.isEmpty { return .openSelection }
        return (try? BookmarkURL.normalize(trimmed)) != nil ? .openURL : .webSearch
    }

    var isTextInputActive: Bool {
        inputKind == .command || inputKind == .search || inputKind == .calc
            || (inputKind == .prompt && prompt?.acceptsText == true
                && prompt?.choicesFocused != true && !customDirectoryFocused)
    }
    var modeLabel: String {
        if customStopConfirmation { return "CONFIRM:STOP" }
        if prompt != nil { return "PROMPT" }
        if buffer == .calc, calcHistoryFocused, inputKind != .command { return "HISTORY" }
        if inputKind == .command { return "COMMAND" }
        if inputKind == .search { return "SEARCH" }
        if let buffer { return "BUFFER:" + buffer.rawValue.uppercased() }
        if busy { return "BUSY" }
        if !query.isEmpty { return "SEARCH" }
        return isOrganizing ? "ORGANIZE" : "NORMAL"
    }

    struct Draft {
        var id: String?
        var kind: TerminalItemKind = .bookmark
        var url = ""
        var title = ""
        var titleEdited = false
        var prefilledFromClipboard = false
        var location = "__root__"
        var folderName = ""
        var path = ""
    }
    var draft = Draft()
    var operationActive = false
    var subscriptions = Set<AnyCancellable>()
    var completionTask: Task<Void, Never>?
    var completionGeneration = 0
    var flashTask: Task<Void, Never>?
    var calcSequence = 0
    var calcFeedbackTask: Task<Void, Never>?
    var history: [String] = []
    var historyIndex: Int?
    var historyDraft = ""
    var commandCompletionPrefix: String?
    var lastCompletedCommand: String?
    struct BufferOrigin {
        var buffer: TerminalBuffer?
        var inputKind: TerminalInputKind?
        var text: String
        var offset: Int
    }
    var bufferOrigin: BufferOrigin?
    var commandOrigin: BufferOrigin?
    var logSequence = 0
    var lastIssue: String?
    var loadedWasLogged = false
    var lastDirectory: URL
    private let defaults: UserDefaults?
    static let expandedDefaultsKey = "frog.expandedGroupIDs"
    static let calcVisibleRows = 16
    let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(store: BookmarkStore, isolated: Bool = false, hotKey: GlobalHotKeyController? = nil,
         hotCorner: HotCornerController? = nil, finderJump: FinderJumpController? = nil,
         defaults: UserDefaults? = nil) {
        self.store = store
        self.isolated = isolated
        self.customStore = CustomCommandStore(directory: isolated ? store.directory : BookmarkStore.defaultDirectory)
        self.login = LoginItemController(isolated: isolated)
        self.hotKey = hotKey
        self.hotCorner = hotCorner
        self.finderJump = finderJump
        self.defaults = defaults ?? (isolated ? nil : .standard)
        if let saved = self.defaults?.stringArray(forKey: Self.expandedDefaultsKey) {
            expandedGroupIDs = Set(saved)
        }
        self.lastDirectory = store.directory
        store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in
            self?.storageChanged()
        }.store(in: &subscriptions)
        login.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in
            self?.rebuildSettings()
        }.store(in: &subscriptions)
        hotKey?.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in
            guard let self else { return }
            self.rebuildSettings()
            if self.prompt?.command == "hotkey", self.hotKey?.recording == false {
                self.finishPrompt()
                if let error = self.hotKey?.error { self.appendLog(error, .error) }
                else { self.appendLog("快捷键已设为 \(self.hotKey?.configuration.shortcut.display ?? "")", .info) }
            } else if self.prompt?.command == "hotkey" {
                self.prompt?.error = self.hotKey?.error
            }
        }.store(in: &subscriptions)
        hotCorner?.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in
            self?.rebuildSettings()
        }.store(in: &subscriptions)
        finderJump?.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in
            self?.rebuildSettings()
        }.store(in: &subscriptions)
        storageChanged()
        loadCustomCommands()
    }

    func storageChanged() {
        busy = operationActive || store.isBusy
        if lastDirectory != store.directory {
            lastDirectory = store.directory
            selectedIndex = 0
            scrollIndex = 0
        }
        rebuildItems()
        rebuildSettings()
        if store.isLoaded && !loadedWasLogged {
            loadedWasLogged = true
            appendLog("已载入 \(document.bookmarks.count) 条书签，\(document.groups.count) 个文件夹", .success)
        }
        if let issue = store.issue, issue != lastIssue { appendLog(issue, .error) }
        lastIssue = store.issue
        if !busy { restoreCalcInputIfNeeded() }
    }

    func rebuildItems(selecting id: String? = nil) {
        let previousID = id ?? (items.indices.contains(selectedIndex) ? items[selectedIndex].id : nil)
        if store.isLoaded {
            let valid = Set(document.groups.map(\.id))
            if !expandedGroupIDs.isSubset(of: valid) {
                expandedGroupIDs = expandedGroupIDs.intersection(valid)
                persistExpanded()
            }
        }
        let groups = document.groups.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        let names = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })
        let counts = Dictionary(grouping: document.bookmarks.compactMap(\.groupId), by: { $0 }).mapValues(\.count)
        func item(_ bookmark: Bookmark, depth: Int = 0) -> TerminalItem {
            let components = URLComponents(string: bookmark.url)
            let host = components?.host ?? ""
            let hostname = host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let detail = components?.port.map { "\(hostname):\($0)" } ?? hostname
            return TerminalItem(id: bookmark.id, kind: .bookmark, title: bookmark.title, detail: detail,
                                url: bookmark.url, groupID: bookmark.groupId,
                                groupName: bookmark.groupId.flatMap { names[$0] } ?? "根目录",
                                depth: depth)
        }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items = document.search(query).map { item($0) }
        } else {
            var next: [TerminalItem] = []
            for group in groups {
                let expanded = expandedGroupIDs.contains(group.id)
                next.append(TerminalItem(id: group.id, kind: .folder, title: group.name,
                                         detail: "\(counts[group.id] ?? 0) 项", expanded: expanded))
                if expanded {
                    next.append(contentsOf: document.bookmarks(in: group.id).map { item($0, depth: 1) })
                }
            }
            next.append(contentsOf: document.bookmarks(in: nil).map { item($0) })
            items = next
        }
        if let previousID, let index = items.firstIndex(where: { $0.id == previousID }) { selectedIndex = index }
        clampSelection()
    }

    func persistExpanded() {
        defaults?.set(expandedGroupIDs.sorted(), forKey: Self.expandedDefaultsKey)
    }

    func selectedGroupID() -> String? {
        guard items.indices.contains(selectedIndex) else { return nil }
        let item = items[selectedIndex]
        return item.kind == .folder ? item.id : item.groupID
    }

    func toggleExpanded(_ id: String) {
        guard prompt == nil, !busy, document.groups.contains(where: { $0.id == id }) else { return }
        let expanding = !expandedGroupIDs.contains(id)
        if expanding { expandedGroupIDs.insert(id) } else { expandedGroupIDs.remove(id) }
        persistExpanded()
        rebuildItems(selecting: id)
        let count = document.bookmarks(in: id).count
        let name = document.groups.first { $0.id == id }?.name ?? ""
        appendLog(expanding ? "已展开“\(name)”（\(count) 项）" : "已折叠“\(name)”", .info)
    }

    func toggleAllExpanded() {
        guard prompt == nil, !busy, buffer == nil,
              query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let ids = Set(document.groups.map(\.id))
        let allOpen = !ids.isEmpty && ids.isSubset(of: expandedGroupIDs)
        let keep = selectedGroupID()
        expandedGroupIDs = allOpen ? [] : ids
        persistExpanded()
        rebuildItems(selecting: keep)
        appendLog(allOpen ? "已折叠全部文件夹" : "已展开全部 \(ids.count) 个文件夹", .info)
    }

    func clampSelection() {
        selectedIndex = min(max(0, selectedIndex), max(0, items.count - 1))
        scrollIndex = min(max(0, scrollIndex), max(0, items.count - visibleRowCount))
        if selectedIndex < scrollIndex { scrollIndex = selectedIndex }
        if selectedIndex >= scrollIndex + visibleRowCount { scrollIndex = selectedIndex - visibleRowCount + 1 }
    }

    func didHide() {
        visible = false
        presented = false
        let wasSearching = inputKind == .search
        let hadQuery = !query.isEmpty
        query = ""
        customQuery = ""
        customIndex = 0
        if wasSearching {
            inputKind = nil
            inputText = ""
            inputRevision &+= 1
        }
        if commandOrigin?.inputKind == .search { commandOrigin?.inputKind = nil; commandOrigin?.text = "" }
        if bufferOrigin?.inputKind == .search { bufferOrigin?.inputKind = nil; bufferOrigin?.text = "" }
        if buffer == .commands, customScreen == .list { bufferOffset = 0 }
        if hadQuery || (wasSearching && buffer == nil) {
            selectedIndex = 0
            scrollIndex = 0
            rebuildItems(selecting: "__reset__")
        }
    }

    var isCommandsEditing: Bool {
        guard buffer == .commands else { return false }
        guard let command = prompt?.command else { return true }
        return command.hasPrefix("commands-")
    }

    func setInput(_ kind: TerminalInputKind, text: String) {
        inputKind = kind
        inputText = text
        inputRevision &+= 1
    }

    func updateInput(_ value: String) {
        guard isTextInputActive, !operationActive else { return }
        if buffer == .commands, inputKind == .search {
            inputText = value
            customQuery = value
            customIndex = 0
            bufferOffset = 0
            return
        }
        if buffer == .commands, prompt?.command == "commands-edit" {
            inputText = value
            prompt?.error = nil
            customFeedback = nil
            captureCustomDraft()
            return
        }
        if inputKind == .calc {
            let filtered = TerminalCalculator.filtered(value)
            inputText = filtered
            calcExpression = filtered
            calcHistoryIndex = nil
            calcError = nil
            setCalcFeedback(nil)
            return
        }
        if inputKind == .prompt, prompt?.field == "title", value != inputText {
            draft.titleEdited = true
        }
        inputText = value
        if inputKind == .search {
            query = value
            selectedIndex = 0
            scrollIndex = 0
            rebuildItems(selecting: "__reset__")
        } else if inputKind == .prompt {
            prompt?.error = nil
            captureDraft()
            refreshPromptChoices(filter: true)
        } else {
            historyIndex = nil
            commandCandidateIndex = nil
            commandCompletionPrefix = nil
            lastCompletedCommand = nil
        }
    }

    func startCommand() {
        guard prompt == nil, !busy, !customStopConfirmation else { return }
        bufferFeedback = nil
        if inputKind != .command {
            commandOrigin = BufferOrigin(buffer: buffer, inputKind: inputKind, text: inputText, offset: bufferOffset)
        }
        historyIndex = nil
        commandCandidateIndex = nil
        historyDraft = ""
        commandCompletionPrefix = nil
        lastCompletedCommand = nil
        setInput(.command, text: "")
    }

    func startSearch() {
        guard prompt == nil, !busy else { return }
        bufferFeedback = nil
        bufferOrigin = nil
        buffer = nil
        isOrganizing = false
        selectedIndex = 0
        scrollIndex = 0
        setInput(.search, text: query)
        rebuildItems(selecting: "__reset__")
    }

    func openSettings() {
        guard prompt == nil, !busy, !customStopConfirmation else { return }
        login.refresh()
        openBuffer(.settings)
        rebuildSettings()
    }

    func openBuffer(_ buffer: TerminalBuffer) {
        guard prompt == nil, !busy else { return }
        bufferFeedback = nil
        if buffer == .calc { bufferOrigin = nil; openCalc(); return }
        if buffer == .commands { bufferOrigin = nil; openCustomCommands(); return }
        if bufferOrigin == nil {
            bufferOrigin = commandOrigin ?? BufferOrigin(buffer: self.buffer, inputKind: inputKind, text: inputText, offset: bufferOffset)
        }
        self.buffer = buffer
        bufferOffset = 0
        inputKind = nil
    }

    func closeBuffer() {
        bufferFeedback = nil
        if let origin = bufferOrigin {
            bufferOrigin = nil
            buffer = origin.buffer
            bufferOffset = origin.offset
            inputKind = origin.inputKind
            inputText = origin.text
            inputRevision &+= 1
            restoreCalcInputIfNeeded()
        } else {
            buffer = nil
            bufferOffset = 0
            inputKind = nil
        }
    }

    func cancelCommand() {
        if let origin = commandOrigin, origin.buffer == buffer {
            inputKind = origin.inputKind
            inputText = origin.text
            inputRevision &+= 1
        } else { inputKind = nil }
        commandOrigin = nil
        restoreCalcInputIfNeeded()
    }

    func selectItem(at index: Int) {
        guard prompt == nil, !busy else { return }
        guard buffer == nil, items.indices.contains(index) else { return }
        selectedIndex = index
        inputKind = nil
        clampSelection()
    }

    func activateSelection() {
        guard prompt == nil, !busy else { return }
        guard buffer == nil else { return }
        if items.isEmpty, !query.isEmpty { openSearch(); return }
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        switch item.kind {
        case .folder: toggleExpanded(item.id)
        case .bookmark:
            guard let value = item.url, let url = URL(string: value) else { return }
            openURL(url, label: item.title)
        }
    }

    func scroll(rows: Int) {
        guard prompt == nil else { return }
        if let buffer {
            let count: Int
            switch buffer {
            case .settings: count = settingsRows.count
            case .help: count = commands.count
            case .log: count = logs.count
            case .job: count = job?.lines.count ?? 0
            case .calc: count = calcHistory.count
            case .commands: count = customScreen == .execution ? customExecutionRows.count : filteredCustomCommands.count
            }
            let capacity: Int
            switch buffer {
            case .settings: capacity = 31
            case .help: capacity = 21
            case .log: capacity = 32
            case .job: capacity = 25
            case .calc: capacity = Self.calcVisibleRows
            case .commands: capacity = Self.calcVisibleRows
            }
            bufferOffset = min(max(0, bufferOffset + rows), max(0, count - capacity))
            if buffer == .commands, customScreen == .list, count > 0 {
                customIndex = min(max(customIndex, bufferOffset), min(count - 1, bufferOffset + capacity - 1))
            }
        } else {
            scrollIndex = min(max(0, scrollIndex + rows), max(0, items.count - visibleRowCount))
            selectedIndex = min(max(selectedIndex, scrollIndex), min(max(0, items.count - 1), scrollIndex + visibleRowCount - 1))
        }
    }

    func escape() {
        guard !operationActive else { return }
        if inputKind == .command { cancelCommand(); return }
        if isCommandsEditing { escapeCustomCommands(); return }
        if let prompt {
            if prompt.choicesFocused {
                self.prompt?.choicesFocused = false
            } else if ["location", "to"].contains(prompt.field), !inputText.isEmpty {
                setInput(.prompt, text: "")
                refreshPromptChoices(filter: false)
            } else {
                if prompt.command == "hotkey" { hotKey?.cancelRecording() }
                finishPrompt()
            }
        } else if buffer == .calc {
            if calcHistoryFocused { focusCalcInput() }
            else { closeBuffer() }
        } else if inputKind == .search || (buffer == nil && !query.isEmpty) {
            query = ""
            inputKind = nil
            selectedIndex = 0
            scrollIndex = 0
            rebuildItems(selecting: "__reset__")
        } else if buffer != nil { closeBuffer() }
        else if isOrganizing { isOrganizing = false }
        else { dismissWindow?() }
    }

    func submitInput() {
        guard !busy else { return }
        if customStopConfirmation { cancelCustomStop(); return }
        if isCommandsEditing, inputKind != .command {
            if customScreen == .edit {
                if customDirectoryFocused { acceptCustomDirectoryChoice() } else { advanceOrSaveCustomDraft() }
            }
            else if customScreen == .delete { escapeCustomCommands() }
            else if inputKind == .search, let command = selectedCustomCommand { executeCustomCommand(command) }
            return
        }
        if let prompt {
            if !prompt.acceptsText {
                if prompt.command != "hotkey" { finishPrompt() }
            } else if prompt.choicesFocused {
                choosePromptOption(at: prompt.selectedChoice)
            } else { advanceOrSubmitPrompt() }
        } else if inputKind == .calc {
            submitCalc()
        } else if inputKind == .command {
            let command = commandCandidateIndex.flatMap { commandCandidates.indices.contains($0) ? commandCandidates[$0].name : nil }
                ?? inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { cancelCommand(); return }
            inputKind = nil
            history.append(command)
            if history.count > 50 { history.removeFirst(history.count - 50) }
            runCommand(command)
            commandOrigin = nil
        } else if inputKind == .search {
            switch searchAction {
            case .finish: escape()
            case .openSelection: activateSelection()
            case .openURL, .webSearch: openSearch()
            }
        }
    }

    func openURL(_ url: URL, label: String) {
        if NSWorkspace.shared.open(url) {
            appendLog("已打开 \(label)", .success)
            inputKind = nil
            dismissWindow?()
        } else { appendLog("无法打开 \(url.absoluteString)", .error) }
    }

    func openSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = try? BookmarkURL.normalize(text), let url = URL(string: value) {
            openURL(url, label: text)
        } else {
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: text)]
            if let url = components.url { openURL(url, label: "Google 搜索“\(text)”") }
        }
    }

    func copySelection() {
        guard let bookmark = selectedBookmark() else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(bookmark.url, forType: .string) {
            appendLog("已复制网址：\(bookmark.title)", .success)
        } else { appendLog("无法写入剪贴板", .error) }
    }
    var canAddCurrentObject: Bool {
        prompt == nil && !busy && !customSaving && !customStopConfirmation && inputKind == nil
            && (buffer == nil || (buffer == .commands && customScreen == .list))
    }

    func addCurrentObject() {
        guard canAddCurrentObject else { return }
        if buffer == .commands { beginCustomEdit() } else { addBookmark() }
    }

    var canDuplicateCurrentCommand: Bool {
        canAddCurrentObject && buffer == .commands && selectedCustomCommand != nil
    }

    func duplicateCurrentCommand() {
        guard canDuplicateCurrentCommand, let command = selectedCustomCommand else { return }
        beginCustomEdit(command, copy: true)
    }

    var canSaveCurrentEditing: Bool {
        guard let prompt, !busy, !customSaving else { return false }
        return !["delete", "hotkey", "commands-delete"].contains(prompt.command) && !customStopConfirmation
    }

    func saveCurrentEditing() {
        guard canSaveCurrentEditing else { return }
        if isCommandsEditing { saveCustomDraft() } else { submitPrompt() }
    }
    var canCopyCurrentObject: Bool {
        prompt == nil && !busy && !customStopConfirmation && (inputKind == nil || inputKind == .calc)
            && (buffer == nil || buffer == .calc || (buffer == .commands && customScreen == .list))
    }

    func copyCurrentObject() {
        guard prompt == nil, !busy else { return }
        switch buffer {
        case nil: copySelection()
        case .calc: copyCalcResult()
        case .commands where customScreen == .list:
            guard let command = selectedCustomCommand else { customFeedback = "没有可复制的命令"; return }
            NSPasteboard.general.clearContents()
            customFeedback = NSPasteboard.general.setString(":" + command.name, forType: .string)
                ? "已复制 :\(command.name)" : "无法写入剪贴板"
        default: appendLog("当前页面没有可复制的内容", .warning)
        }
    }

    func navigateFolder(expanding: Bool) {
        guard query.isEmpty, items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        guard let id = item.kind == .folder ? item.id : (expanding ? nil : item.groupID) else { return }
        if expandedGroupIDs.contains(id) != expanding { toggleExpanded(id) }
    }

    func selectedBookmark() -> Bookmark? {
        guard items.indices.contains(selectedIndex), items[selectedIndex].kind == .bookmark,
              let bookmark = document.bookmarks.first(where: { $0.id == items[selectedIndex].id }) else {
            appendLog("请选择书签", .error)
            return nil
        }
        return bookmark
    }

    func toggleOrganizing() {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            appendLog("搜索时无法整理，请先按 Esc 清空搜索", .warning)
            return
        }
        isOrganizing.toggle()
    }

    func reorderSelection(_ direction: Int) {
        guard isOrganizing, query.isEmpty, !busy,
              items.indices.contains(selectedIndex), items[selectedIndex].kind == .bookmark else { return }
        let bookmarks = document.bookmarks(in: items[selectedIndex].groupID)
        let id = items[selectedIndex].id
        guard let from = bookmarks.firstIndex(where: { $0.id == id }), bookmarks.indices.contains(from + direction) else { return }
        dropBookmark(sourceID: id, targetID: bookmarks[from + direction].id, before: direction < 0, merge: false)
    }

    func dropBookmark(sourceID: String, targetID: String?, before: Bool, merge: Bool) {
        guard isOrganizing, query.isEmpty, prompt == nil, !busy,
              document.bookmarks.contains(where: { $0.id == sourceID }), sourceID != targetID else { return }
        let destinationGroupID: String? = targetID.map { id in
            document.groups.contains(where: { $0.id == id })
                ? id
                : document.bookmarks.first(where: { $0.id == id })?.groupId
        } ?? nil
        if let destinationGroupID { expandedGroupIDs.insert(destinationGroupID) }
        mutate("已移动书签", closePrompt: false) { document in
            guard let source = document.bookmarks.first(where: { $0.id == sourceID }) else {
                throw BookmarkError.invalidData("书签已不存在")
            }
            if merge {
                guard let targetID, source.groupId == nil,
                      document.bookmarks.contains(where: { $0.id == targetID && $0.groupId == nil }) else {
                    throw BookmarkError.invalidData("仅可合并根目录下的书签")
                }
                var name = "新建文件夹"
                var suffix = 2
                while document.groups.contains(where: { $0.name == name }) { name = "新建文件夹 \(suffix)"; suffix += 1 }
                let group = try document.addGroup(name: name)
                try document.moveBookmark(id: targetID, to: group)
                try document.moveBookmark(id: sourceID, to: group)
                return group
            }
            if let targetID, document.groups.contains(where: { $0.id == targetID }) {
                try document.moveBookmark(id: sourceID, to: targetID)
                return sourceID
            }
            guard let targetID else {
                try document.moveBookmark(id: sourceID, to: nil)
                return sourceID
            }
            guard let target = document.bookmarks.first(where: { $0.id == targetID }) else {
                throw BookmarkError.invalidData("拖拽目标已变化，请重试")
            }
            let peers = document.bookmarks(in: target.groupId).filter { $0.id != sourceID }
            let index = peers.firstIndex { $0.id == targetID }!
            let next = before ? targetID : (index + 1 < peers.count ? peers[index + 1].id : nil)
            try document.moveBookmark(id: sourceID, to: target.groupId, before: next)
            return sourceID
        }
    }

    func mutate(_ message: String, closePrompt: Bool = true,
                _ mutation: @escaping (inout BookmarkDocument) throws -> String?) {
        guard !busy else { return }
        operationActive = true
        busy = true
        Task { [self] in
            do {
                var selection: String?
                try await store.apply { selection = try mutation(&$0) }
                if let selection,
                   let groupID = document.bookmarks.first(where: { $0.id == selection })?.groupId {
                    expandedGroupIDs.insert(groupID)
                }
                if closePrompt { finishPrompt() }
                rebuildItems(selecting: selection)
                persistExpanded()
                appendLog(message, .success)
            } catch {
                prompt?.error = error.localizedDescription
                appendLog(error.localizedDescription, .error)
            }
            operationActive = false
            busy = store.isBusy
            rebuildSettings()
            restoreCalcInputIfNeeded()
        }
    }

    func makeEntry(_ text: String, _ level: TerminalLevel) -> TerminalLogEntry {
        logSequence &+= 1
        return TerminalLogEntry(id: logSequence, time: clockFormatter.string(from: Date()), text: text, level: level)
    }

    func appendLog(_ text: String, _ level: TerminalLevel = .info) {
        logs.append(makeEntry(text, level))
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
        if let row = settingsRows.firstIndex(where: { $0.key == "log" }) {
            settingsRows[row].value = "\(logs.count) 条"
        }
        if buffer == .log { bufferOffset = min(bufferOffset, max(0, logs.count - 32)) }
    }

    func handleKey(_ event: NSEvent, isTextEditing: Bool) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let text = event.charactersIgnoringModifiers ?? ""
        if customStopConfirmation { return handleCustomCommandKey(event, isTextEditing: isTextEditing) }
        if modifiers == .command {
            if text == "," { openSettings(); return true }
            if text.lowercased() == "c", canCopyCurrentObject { copyCurrentObject(); return true }
            if text.lowercased() == "n" { addCurrentObject(); return true }
            if buffer == .calc, inputKind != .command, prompt == nil, event.keyCode == 51 {
                return handleCalcKey(event, characters: event.characters ?? "")
            }
        }
        if isCommandsEditing, inputKind != .command { return handleCustomCommandKey(event, isTextEditing: isTextEditing) }
        if let prompt {
            if prompt.command == "hotkey" { return false }
            return handlePromptKey(event)
        }
        if inputKind == .command, modifiers == .option, [125, 126].contains(event.keyCode) {
            commandCandidateIndex = nil
            recallHistory(event.keyCode == 126 ? -1 : 1)
            return true
        }
        if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) { return false }
        if event.keyCode == 53, modifiers.isEmpty { escape(); return true }
        if buffer == .calc, inputKind != .command { return handleCalcKey(event, characters: event.characters ?? "") }
        if inputKind == .command {
            guard modifiers.isEmpty || (modifiers == .shift && event.keyCode == 48) else { return false }
            switch event.keyCode {
            case 36, 76: submitInput(); return true
            case 48: completeCommand(backward: modifiers == .shift); return true
            case 125, 126:
                moveCommandCandidate(event.keyCode == 126 ? -1 : 1); return true
            default: return false
            }
        }
        if inputKind == .search {
            guard modifiers.isEmpty || (modifiers == .shift && event.keyCode == 48) else { return false }
            switch event.keyCode {
            case 36, 76: submitInput(); return true
            case 48: selectItem(at: selectedIndex); return true
            case 125, 126: moveCursor(event.keyCode == 125 ? 1 : -1); return true
            default: return false
            }
        }
        if isTextEditing { return false }
        if event.keyCode == 48 {
            if buffer == nil, modifiers == .shift, !query.isEmpty { setInput(.search, text: query) }
            return true
        }
        if text == ":", modifiers.isEmpty || modifiers == .shift { startCommand(); return true }
        if buffer != nil {
            if text == "/", modifiers.isEmpty { bufferOrigin = nil; startSearch(); return true }
            if text == "?", modifiers == .shift { openBuffer(.help); return true }
            guard modifiers.isEmpty || (modifiers == .shift && text == "G") else { return false }
            switch event.keyCode {
            case 125: moveBuffer(1); return true
            case 126: moveBuffer(-1); return true
            case 121: scroll(rows: 18); return true
            case 116: scroll(rows: -18); return true
            default: break
            }
            if text == "j" { moveBuffer(1); return true }
            if text == "k" { moveBuffer(-1); return true }
            if text == "g" { bufferOffset = 0; return true }
            if text == "G" { scroll(rows: Int.max / 2); return true }
            return false
        }
        if isOrganizing, modifiers == .shift, [125, 126].contains(event.keyCode) {
            reorderSelection(event.keyCode == 125 ? 1 : -1); return true
        }
        guard modifiers.isEmpty || (modifiers == .shift && ["D", "G", "?"].contains(text)) else { return false }
        switch event.keyCode {
        case 125: moveCursor(1); return true
        case 126: moveCursor(-1); return true
        case 121: moveCursor(visibleRowCount); return true
        case 116: moveCursor(-visibleRowCount); return true
        case 123: navigateFolder(expanding: false); return true
        case 124: navigateFolder(expanding: true); return true
        case 36, 76: activateSelection(); return true
        default: break
        }
        switch text {
        case "j": moveCursor(1)
        case "k": moveCursor(-1)
        case "g": selectedIndex = 0; clampSelection()
        case "G": selectedIndex = max(0, items.count - 1); clampSelection()
        case "/": startSearch()
        case "a": addCurrentObject()
        case "n": beginMkdir()
        case "e":
            if items.indices.contains(selectedIndex), items[selectedIndex].kind == .folder { beginRename() }
            else { beginEdit() }
        case "m": beginMove()
        case "D": requestDeleteSelection()
        case "o": toggleOrganizing()
        case "z": toggleAllExpanded()
        case "?": openBuffer(.help)
        case ",": openSettings()
        default: return false
        }
        return true
    }

    func moveCursor(_ delta: Int) {
        selectedIndex = min(max(0, selectedIndex + delta), max(0, items.count - 1))
        clampSelection()
    }

    func moveBuffer(_ delta: Int) {
        scroll(rows: delta)
    }
}
