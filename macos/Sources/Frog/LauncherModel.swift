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
    @Published var folderID: String?
    @Published var query = ""
    @Published var buffer: TerminalBuffer?
    @Published var bufferOffset = 0
    @Published var atlasIndex = 0
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
    let commands = LauncherModel.commandDirectory

    var dismissWindow: (() -> Void)?
    var terminateApplication: (() -> Void)?
    var document: BookmarkDocument { store.document }
    var folderName: String { document.groups.first { $0.id == folderID }?.name ?? "根目录" }
    var showBreadcrumb: Bool { folderID != nil && query.isEmpty && buffer == nil }
    var visibleRowCount: Int { showBreadcrumb ? 18 : 19 }
    var isTextInputActive: Bool {
        inputKind == .command || inputKind == .search || (inputKind == .prompt && prompt?.acceptsText == true)
    }
    var modeLabel: String {
        if prompt != nil { return "PROMPT" }
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
        var title: String?
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
    var history: [String] = []
    var historyIndex: Int?
    var historyDraft = ""
    var commandCompletionPrefix: String?
    var lastCompletedCommand: String?
    var logSequence = 0
    var lastIssue: String?
    var loadedWasLogged = false
    var lastDirectory: URL
    private let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(store: BookmarkStore, isolated: Bool = false, hotKey: GlobalHotKeyController? = nil,
         hotCorner: HotCornerController? = nil, finderJump: FinderJumpController? = nil) {
        self.store = store
        self.isolated = isolated
        self.login = LoginItemController(isolated: isolated)
        self.hotKey = hotKey
        self.hotCorner = hotCorner
        self.finderJump = finderJump
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
                else { self.appendLog("快捷键录入已结束；当前绑定：\(self.hotKey?.configuration.shortcut.display ?? "")", .info) }
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
    }

    func storageChanged() {
        busy = operationActive || store.isBusy
        if lastDirectory != store.directory {
            lastDirectory = store.directory
            folderID = nil
            selectedIndex = 0
            scrollIndex = 0
        }
        rebuildItems()
        rebuildSettings()
        if store.isLoaded && !loadedWasLogged {
            loadedWasLogged = true
            appendLog("青蛙导航 · \(document.bookmarks.count) bookmarks · \(document.groups.count) groups · UTF-8", .success)
            appendLog("输入 : 打开命令 · / 搜索 · ? 帮助", .info)
        }
        if let issue = store.issue, issue != lastIssue { appendLog(issue, .error) }
        lastIssue = store.issue
    }

    func rebuildItems(selecting id: String? = nil) {
        let previousID = id ?? (items.indices.contains(selectedIndex) ? items[selectedIndex].id : nil)
        if let folderID, !document.groups.contains(where: { $0.id == folderID }) { self.folderID = nil }
        let groups = document.groups.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        let names = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })
        let counts = Dictionary(grouping: document.bookmarks.compactMap(\.groupId), by: { $0 }).mapValues(\.count)
        func item(_ bookmark: Bookmark) -> TerminalItem {
            let components = URLComponents(string: bookmark.url)
            let host = components?.host ?? ""
            let hostname = host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let detail = components?.port.map { "\(hostname):\($0)" } ?? hostname
            return TerminalItem(id: bookmark.id, kind: .bookmark, title: bookmark.title, detail: detail,
                                url: bookmark.url, groupID: bookmark.groupId,
                                groupName: bookmark.groupId.flatMap { names[$0] } ?? "根目录")
        }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items = document.search(query).map(item)
        } else {
            var next: [TerminalItem] = []
            if folderID == nil {
                next = groups.map { TerminalItem(id: $0.id, kind: .folder, title: $0.name,
                                                detail: "\(counts[$0.id] ?? 0) 项") }
            } else {
                next.append(TerminalItem(id: "__add__", kind: .add, title: "添加书签", detail: ":add"))
            }
            next.append(contentsOf: document.bookmarks(in: folderID).map(item))
            items = next
        }
        if let previousID, let index = items.firstIndex(where: { $0.id == previousID }) { selectedIndex = index }
        clampSelection()
    }

    func clampSelection() {
        selectedIndex = min(max(0, selectedIndex), max(0, items.count - 1))
        scrollIndex = min(max(0, scrollIndex), max(0, items.count - visibleRowCount))
        if selectedIndex < scrollIndex { scrollIndex = selectedIndex }
        if selectedIndex >= scrollIndex + visibleRowCount { scrollIndex = selectedIndex - visibleRowCount + 1 }
    }

    func didHide() { visible = false; presented = false }

    func setInput(_ kind: TerminalInputKind, text: String) {
        inputKind = kind
        inputText = text
        inputRevision &+= 1
    }

    func updateInput(_ value: String) {
        guard isTextInputActive, !operationActive else { return }
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
            commandCompletionPrefix = nil
            lastCompletedCommand = nil
        }
    }

    func startCommand() {
        guard prompt == nil, !busy else { return }
        historyIndex = nil
        historyDraft = ""
        commandCompletionPrefix = nil
        lastCompletedCommand = nil
        setInput(.command, text: "")
    }

    func startSearch() {
        guard prompt == nil, !busy else { return }
        buffer = nil
        isOrganizing = false
        selectedIndex = 0
        scrollIndex = 0
        setInput(.search, text: query)
        rebuildItems(selecting: "__reset__")
    }

    func openSettings() {
        guard prompt == nil, !busy else { return }
        login.refresh()
        openBuffer(.settings)
        rebuildSettings()
    }

    func openBuffer(_ buffer: TerminalBuffer) {
        guard prompt == nil, !busy else { return }
        self.buffer = buffer
        bufferOffset = 0
        inputKind = nil
        if buffer == .atlas { atlasIndex = 0 }
    }

    func selectItem(at index: Int) {
        guard prompt == nil, !busy else { return }
        if buffer == .atlas {
            guard commands.indices.contains(index) else { return }
            atlasIndex = index
            inputKind = nil
            return
        }
        guard buffer == nil, items.indices.contains(index) else { return }
        selectedIndex = index
        inputKind = nil
        clampSelection()
    }

    func activateSelection() {
        guard prompt == nil, !busy else { return }
        if buffer == .atlas {
            guard commands.indices.contains(atlasIndex) else { return }
            let command = commands[atlasIndex]
            buffer = nil
            if command.name == "group" {
                setInput(.command, text: command.name + " ")
            } else { runCommand(command.name) }
            return
        }
        guard buffer == nil else { return }
        if items.isEmpty, !query.isEmpty { openSearch(); return }
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        switch item.kind {
        case .add: addBookmark()
        case .folder: enterFolder(item.id)
        case .bookmark:
            guard let value = item.url, let url = URL(string: value) else { return }
            openURL(url, label: item.title)
        }
    }

    func enterFolder(_ id: String) {
        guard document.groups.contains(where: { $0.id == id }) else { appendLog("文件夹已不存在。", .error); return }
        folderID = id
        query = ""
        buffer = nil
        inputKind = nil
        selectedIndex = document.bookmarks(in: id).isEmpty ? 0 : 1
        scrollIndex = 0
        rebuildItems(selecting: "__reset__")
    }

    func closeFolder() {
        guard prompt == nil, !busy else { return }
        let id = folderID
        folderID = nil
        query = ""
        inputKind = nil
        selectedIndex = 0
        scrollIndex = 0
        rebuildItems(selecting: id)
    }

    func scroll(rows: Int) {
        guard prompt == nil else { return }
        if let buffer {
            let count: Int
            switch buffer {
            case .settings: count = settingsRows.count
            case .help, .atlas: count = commands.count
            case .log: count = logs.count
            case .job: count = job?.lines.count ?? 0
            }
            let capacity: Int
            switch buffer {
            case .settings: capacity = 31
            case .help: capacity = 20
            case .log: capacity = 32
            case .job: capacity = 25
            case .atlas: capacity = 18
            }
            bufferOffset = min(max(0, bufferOffset + rows), max(0, count - capacity))
            if buffer == .atlas {
                atlasIndex = min(max(atlasIndex, bufferOffset), min(max(0, count - 1), bufferOffset + capacity - 1))
            }
        } else {
            scrollIndex = min(max(0, scrollIndex + rows), max(0, items.count - visibleRowCount))
            selectedIndex = min(max(selectedIndex, scrollIndex), min(max(0, items.count - 1), scrollIndex + visibleRowCount - 1))
        }
    }

    func escape() {
        guard !operationActive else { return }
        if prompt != nil {
            if prompt?.command == "hotkey" { hotKey?.cancelRecording() }
            finishPrompt()
        } else if inputKind != nil {
            if inputKind == .search { query = ""; selectedIndex = 0; scrollIndex = 0; rebuildItems(selecting: "__reset__") }
            inputKind = nil
        } else if buffer != nil { buffer = nil; bufferOffset = 0 }
        else if isOrganizing { isOrganizing = false }
        else if !query.isEmpty { query = ""; selectedIndex = 0; scrollIndex = 0; rebuildItems(selecting: "__reset__") }
        else if folderID != nil { closeFolder() }
        else { dismissWindow?() }
    }

    func submitInput() {
        guard !busy else { return }
        if let prompt {
            if !prompt.acceptsText {
                if prompt.command != "hotkey" { finishPrompt() }
            } else { submitPrompt() }
        } else if inputKind == .command {
            let command = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            inputKind = nil
            if !command.isEmpty {
                history.append(command)
                if history.count > 50 { history.removeFirst(history.count - 50) }
                runCommand(command)
            }
        } else if inputKind == .search {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { escape() }
            else { activateSelection() }
        }
    }

    func openURL(_ url: URL, label: String) {
        if NSWorkspace.shared.open(url) {
            appendLog("已打开 \(label) · \(url.absoluteString)", .success)
            inputKind = nil
            dismissWindow?()
        } else { appendLog("系统未能打开 \(url.absoluteString)", .error) }
    }

    func openSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = try? BookmarkURL.normalize(text), let url = URL(string: value) {
            openURL(url, label: text)
        } else {
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: text)]
            if let url = components.url { openURL(url, label: "搜索 “\(text)”") }
        }
    }

    func copySelection() {
        guard let bookmark = selectedBookmark() else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(bookmark.url, forType: .string) {
            appendLog("已复制链接 \(bookmark.url)", .success)
        } else { appendLog("系统剪贴板未能写入链接。", .error) }
    }

    func selectedBookmark() -> Bookmark? {
        guard items.indices.contains(selectedIndex), items[selectedIndex].kind == .bookmark,
              let bookmark = document.bookmarks.first(where: { $0.id == items[selectedIndex].id }) else {
            appendLog("请选择书签。", .error)
            return nil
        }
        return bookmark
    }

    func toggleOrganizing() {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            appendLog("搜索结果不能排序；先按 Esc 清空搜索。", .warning)
            return
        }
        isOrganizing.toggle()
    }

    func reorderSelection(_ direction: Int) {
        guard isOrganizing, query.isEmpty, !busy,
              items.indices.contains(selectedIndex), items[selectedIndex].kind == .bookmark else { return }
        let bookmarks = document.bookmarks(in: folderID)
        let id = items[selectedIndex].id
        guard let from = bookmarks.firstIndex(where: { $0.id == id }), bookmarks.indices.contains(from + direction) else { return }
        dropBookmark(sourceID: id, targetID: bookmarks[from + direction].id, before: direction < 0, merge: false)
    }

    func dropBookmark(sourceID: String, targetID: String?, before: Bool, merge: Bool) {
        guard isOrganizing, query.isEmpty, prompt == nil, !busy,
              document.bookmarks.contains(where: { $0.id == sourceID }), sourceID != targetID else { return }
        if targetID == "__add__" { return }
        let currentFolder = folderID
        mutate("已移动书签", closePrompt: false) { document in
            guard let source = document.bookmarks.first(where: { $0.id == sourceID }) else {
                throw BookmarkError.invalidData("书签已不存在。")
            }
            if merge {
                guard let targetID, source.groupId == nil,
                      document.bookmarks.contains(where: { $0.id == targetID && $0.groupId == nil }) else {
                    throw BookmarkError.invalidData("仅可将两条根目录书签合并。")
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
            guard let target = document.bookmarks.first(where: { $0.id == targetID }), target.groupId == currentFolder else {
                throw BookmarkError.invalidData("拖拽目标已改变，请重试。")
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
                if closePrompt { finishPrompt() }
                rebuildItems(selecting: selection)
                appendLog(message, .success)
            } catch {
                prompt?.error = error.localizedDescription
                appendLog(error.localizedDescription, .error)
            }
            operationActive = false
            busy = store.isBusy
            rebuildSettings()
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
            settingsRows[row].value = "\(logs.count) lines"
        }
        if buffer == .log { bufferOffset = min(bufferOffset, max(0, logs.count - 32)) }
    }

    func handleKey(_ event: NSEvent, isTextEditing: Bool) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let text = event.charactersIgnoringModifiers ?? ""
        if modifiers.contains(.command) {
            if modifiers == .command, text == "," { openSettings(); return true }
            if modifiers == .command, text.lowercased() == "n" { addBookmark(); return true }
            return false
        }
        if modifiers.contains(.control) || modifiers.contains(.option) { return false }
        if event.keyCode == 53 { escape(); return true }
        if let prompt {
            if prompt.command == "hotkey" { return false }
            if !prompt.acceptsText {
                if text.lowercased() == "y" { confirmPrompt(); return true }
                if text.lowercased() == "n" || [36, 76].contains(event.keyCode) { escape(); return true }
                return false
            }
            switch event.keyCode {
            case 36, 76: submitInput(); return true
            case 48:
                if prompt.command == "edit" { switchEditField() }
                else if modifiers.contains(.shift) { previousPrompt() }
                else { cyclePromptChoice(1) }
                return true
            case 125, 126:
                guard !prompt.choices.isEmpty else { return false }
                cyclePromptChoice(event.keyCode == 125 ? 1 : -1)
                return true
            default: return false
            }
        }
        if inputKind == .command {
            switch event.keyCode {
            case 36, 76: submitInput(); return true
            case 48: completeCommand(backward: modifiers.contains(.shift)); return true
            case 125, 126: recallHistory(event.keyCode == 126 ? -1 : 1); return true
            default: return false
            }
        }
        if inputKind == .search {
            switch event.keyCode {
            case 36, 76: submitInput(); return true
            case 125, 126: moveCursor(event.keyCode == 125 ? 1 : -1); return true
            default: return false
            }
        }
        if isTextEditing { return false }
        if text == ":" { startCommand(); return true }
        if buffer == .settings { return true }
        if event.keyCode == 122 {
            if buffer == .atlas { buffer = nil; bufferOffset = 0 }
            else { openBuffer(.atlas) }
            return true
        }
        if let buffer {
            if text == "/" { self.buffer = nil; bufferOffset = 0; startSearch(); return true }
            if text == "?" { openBuffer(.help); return true }
            switch event.keyCode {
            case 125: moveBuffer(1); return true
            case 126: moveBuffer(-1); return true
            case 121: scroll(rows: 18); return true
            case 116: scroll(rows: -18); return true
            case 36, 76: if buffer == .atlas { activateSelection() }; return true
            default: break
            }
            if text == "j" { moveBuffer(1); return true }
            if text == "k" { moveBuffer(-1); return true }
            if text == "g" { bufferOffset = 0; atlasIndex = 0; return true }
            if text == "G" { scroll(rows: Int.max / 2); if buffer == .atlas { atlasIndex = max(0, commands.count - 1) }; return true }
            return false
        }
        if isOrganizing && modifiers.contains(.shift) && ([125, 126].contains(event.keyCode) || ["J", "K"].contains(text)) {
            reorderSelection(event.keyCode == 125 || text == "J" ? 1 : -1)
            return true
        }
        switch event.keyCode {
        case 125: moveCursor(1); return true
        case 126: moveCursor(-1); return true
        case 121: moveCursor(visibleRowCount); return true
        case 116: moveCursor(-visibleRowCount); return true
        case 36, 76: activateSelection(); return true
        default: break
        }
        switch text {
        case "j": moveCursor(1)
        case "k": moveCursor(-1)
        case "g": selectedIndex = 0; clampSelection()
        case "G": selectedIndex = max(0, items.count - 1); clampSelection()
        case "/": startSearch()
        case "a": addBookmark()
        case "n": beginMkdir()
        case "e": beginEdit()
        case "r": beginRename()
        case "m": beginMove()
        case "D": requestDeleteSelection()
        case "C": copySelection()
        case "o": toggleOrganizing()
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
        if buffer == .atlas {
            atlasIndex = min(max(0, atlasIndex + delta), max(0, commands.count - 1))
            if atlasIndex < bufferOffset { bufferOffset = atlasIndex }
            if atlasIndex >= bufferOffset + 18 { bufferOffset = atlasIndex - 17 }
        } else { scroll(rows: delta) }
    }
}
