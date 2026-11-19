import AppKit
import FrogCore

struct BookmarkSummaryRow: Equatable {
    let field: String
    let label: String
    let value: String
    let placeholder: String?
    let active: Bool
}

extension LauncherModel {
    func beginPrompt(_ command: String, step: Int = 0, total: Int = 0, field: String, value: String,
                     hint: String = "Enter 提交 · Esc 取消", acceptsText: Bool = true) {
        prompt = TerminalPrompt(command: command, step: step, total: total, field: field,
                                hint: hint, acceptsText: acceptsText)
        setInput(.prompt, text: value)
        refreshPromptChoices(filter: false)
    }

    func finishPrompt() {
        completionGeneration &+= 1
        completionTask?.cancel()
        completionTask = nil
        customDirectoryLoading = false
        customDirectoryFocused = false
        customDirectoryPath = ""
        customDirectoryPreselectPath = nil
        customDeleteTarget = nil
        prompt = nil
        inputKind = nil
        draft = Draft()
        // 异步提交期间 busy 仍为 true，这里直接恢复计算器，而不是等待 busy 清零。
        if buffer == .calc, !calcHistoryFocused { setInput(.calc, text: calcExpression) }
    }

    static func suggestedTitle(for rawURL: String) -> String {
        guard let normalized = try? BookmarkURL.normalize(rawURL),
              let components = URLComponents(string: normalized),
              let host = components.host, !host.isEmpty else { return "" }
        let hostname = host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if let port = components.port { return "\(hostname):\(port)" }
        return hostname
    }

    var duplicateBookmarkForDraft: (bookmark: Bookmark, locationName: String)? {
        guard let command = prompt?.command, ["add", "edit"].contains(command),
              let normalized = try? BookmarkURL.normalize(draft.url),
              let existing = document.bookmarks.first(where: { $0.url == normalized && $0.id != draft.id }) else {
            return nil
        }
        let location = existing.groupId.flatMap { id in document.groups.first(where: { $0.id == id })?.name } ?? "根目录"
        return (existing, location)
    }

    func draftLocationName(for id: String) -> String {
        if id == "__root__" { return "根目录" }
        if id == "__new__" { return "新建文件夹…" }
        return document.groups.first(where: { $0.id == id })?.name ?? "根目录"
    }

    var bookmarkSummaryRows: [BookmarkSummaryRow] {
        guard let prompt, ["add", "edit"].contains(prompt.command) else { return [] }
        let fields = promptFields(command: prompt.command)
        let autoTitle = Self.suggestedTitle(for: draft.url)
        return fields.map { field in
            switch field {
            case "url":
                return BookmarkSummaryRow(field: field, label: "网址", value: draft.url,
                                          placeholder: "输入网址", active: prompt.field == field)
            case "title":
                return BookmarkSummaryRow(field: field, label: "标题", value: draft.title,
                                          placeholder: autoTitle.isEmpty ? "输入标题" : autoTitle,
                                          active: prompt.field == field)
            case "location":
                return BookmarkSummaryRow(field: field, label: "位置",
                                          value: draftLocationName(for: draft.location),
                                          placeholder: nil, active: prompt.field == field)
            default:
                return BookmarkSummaryRow(field: field, label: "新文件夹", value: draft.folderName,
                                          placeholder: "输入文件夹名称", active: prompt.field == field)
            }
        }
    }

    func addBookmark() {
        guard prompt == nil, !busy else { return }
        buffer = nil
        let defaultLocation = selectedGroupID() ?? "__root__"
        var initialURL = ""
        var initialTitle = ""
        var fromClipboard = false
        if let raw = readClipboardString()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty, !raw.contains(where: \.isNewline),
           (raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://")),
           BookmarkURL.isValid(raw) {
            initialURL = raw
            initialTitle = Self.suggestedTitle(for: raw)
            fromClipboard = true
        }
        draft = Draft(url: initialURL, title: initialTitle, titleEdited: false,
                      prefilledFromClipboard: fromClipboard, location: defaultLocation)
        showBookmarkField(command: "add", field: "url")
    }

    func beginEdit(urlFirst: Bool = false) {
        guard prompt == nil, !busy, let bookmark = selectedBookmark() else { return }
        draft = Draft(id: bookmark.id, url: bookmark.url, title: bookmark.title, titleEdited: true,
                      location: bookmark.groupId ?? "__root__")
        showBookmarkField(command: "edit", field: urlFirst ? "url" : "title")
    }

    func beginRename() {
        guard prompt == nil, !busy else { return }
        guard items.indices.contains(selectedIndex), items[selectedIndex].kind == .folder,
              let group = document.groups.first(where: { $0.id == items[selectedIndex].id }) else {
            appendLog("请选择文件夹", .error)
            return
        }
        draft = Draft(id: group.id, kind: .folder, folderName: group.name)
        beginPrompt("rename", field: "name", value: group.name, hint: "Enter 保存 · Esc 放弃修改")
    }

    func beginMkdir() {
        guard prompt == nil, !busy else { return }
        draft = Draft()
        beginPrompt("mkdir", field: "name", value: "", hint: "Enter 创建 · Esc 取消")
    }

    func beginMove() {
        guard prompt == nil, !busy, let bookmark = selectedBookmark() else { return }
        draft = Draft(id: bookmark.id, title: bookmark.title,
                      location: bookmark.groupId == nil ? "__new__" : "__root__")
        let options = locationChoices(for: "move").filter { $0.id != (bookmark.groupId ?? "__root__") }
        draft.location = options.first?.id ?? "__new__"
        showLocation(command: "move")
    }

    func requestDeleteSelection() {
        guard prompt == nil, !busy, items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        if item.kind == .folder && document.bookmarks.contains(where: { $0.groupId == item.id }) {
            appendLog("仅可删除空文件夹", .error)
            return
        }
        draft = Draft(id: item.id, kind: item.kind, title: item.title)
        beginPrompt("delete", field: "confirm", value: "",
                    hint: "删除“\(item.title)”？y 删除 · Esc 取消", acceptsText: false)
    }

    func captureDraft() {
        guard let prompt else { return }
        switch prompt.field {
        case "title":
            draft.title = inputText
        case "url":
            draft.url = inputText
            if !draft.titleEdited { draft.title = Self.suggestedTitle(for: inputText) }
        case "name", "folder":
            draft.folderName = inputText
        case "path", "file":
            draft.path = inputText
        default:
            break
        }
    }

    func promptFields(command: String) -> [String] {
        var fields: [String]
        switch command {
        case "move": fields = ["to"]
        case "edit": fields = ["title", "url", "location"]
        default: fields = ["url", "title", "location"]
        }
        if draft.location == "__new__" { fields.append("folder") }
        return fields
    }

    func showBookmarkField(command: String, field: String) {
        if !draft.titleEdited {
            draft.title = Self.suggestedTitle(for: draft.url)
        }
        let fields = promptFields(command: command)
        let value: String
        switch field {
        case "url": value = draft.url
        case "title": value = draft.title
        case "folder": value = draft.folderName
        default: value = ""
        }
        let hint: String
        switch (command, field) {
        case ("add", "url"), ("add", "title"):
            hint = "Enter 下一步 · Tab 切字段 · ⌘Enter 保存 · Esc 放弃修改"
        case ("add", "location"):
            hint = "↑↓ 选择 · Enter 保存 · Tab 切字段 · Esc 放弃修改"
        case ("add", "folder"):
            hint = "Enter 保存 · Tab 切字段 · Esc 放弃修改"
        case ("edit", "location"):
            hint = "↑↓ 选择 · Enter 保存 · Tab 切字段 · Esc 放弃修改"
        case ("edit", _):
            hint = "Enter 保存 · Tab 切字段 · Esc 放弃修改"
        case ("move", "to"):
            hint = "↑↓ 选择 · Enter 移动 · Esc 取消"
        default:
            hint = "Enter 创建并移动 · ⇧Tab 返回位置 · Esc 取消"
        }
        beginPrompt(command, step: fields.firstIndex(of: field) ?? 0, total: fields.count,
                    field: field, value: value, hint: hint)
    }

    func selectBookmarkPromptField(_ field: String) {
        guard let prompt, !busy, ["add", "edit", "move"].contains(prompt.command),
              prompt.field != field, promptFields(command: prompt.command).contains(field) else { return }
        captureDraft()
        showBookmarkField(command: prompt.command, field: field)
    }

    func switchPromptField(_ direction: Int) {
        guard let prompt, !busy else { return }
        captureDraft()
        guard ["add", "edit", "move"].contains(prompt.command) else {
            self.prompt?.choicesFocused = !prompt.choicesFocused && !prompt.choices.isEmpty
            return
        }
        let fields = promptFields(command: prompt.command)
        let index = fields.firstIndex(of: prompt.field) ?? 0
        let next = (index + direction + fields.count) % fields.count
        showBookmarkField(command: prompt.command, field: fields[next])
    }

    func showLocation(command: String) {
        showBookmarkField(command: command, field: command == "move" ? "to" : "location")
    }

    func handlePromptKey(_ event: NSEvent) -> Bool {
        guard let prompt, !busy else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if prompt.command == "delete" {
            guard modifiers.isEmpty else { return false }
            if event.charactersIgnoringModifiers == "y" { confirmPrompt(); return true }
            if event.charactersIgnoringModifiers == "n" || [36, 76, 53].contains(event.keyCode) {
                finishPrompt()
                return true
            }
            return false
        }
        if [36, 76].contains(event.keyCode), modifiers == .command {
            submitPrompt()
            return true
        }
        if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift {
            switchPromptField(modifiers == .shift ? -1 : 1)
            return true
        }
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 53:
            escape()
        case 36, 76:
            if prompt.choicesFocused { choosePromptOption(at: prompt.selectedChoice) }
            else { advanceOrSubmitPrompt() }
        case 125, 126:
            if ["location", "to"].contains(prompt.field), !prompt.choices.isEmpty {
                cyclePromptChoice(event.keyCode == 125 ? 1 : -1)
            } else if prompt.choicesFocused {
                cyclePromptChoice(event.keyCode == 125 ? 1 : -1)
            } else {
                return false
            }
        default: return false
        }
        return true
    }

    func locationChoices(for command: String? = nil) -> [TerminalChoice] {
        let activeCommand = command ?? prompt?.command
        var choices = [TerminalChoice(id: "__root__", label: "根目录")]
        choices += document.groups.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
            .map { TerminalChoice(id: $0.id, label: $0.name,
                                  detail: "\(document.bookmarks(in: $0.id).count) 项") }
        choices.append(TerminalChoice(id: "__new__", label: "新建文件夹…", detail: "输入名称"))
        if activeCommand == "move" {
            if let bookmark = document.bookmarks.first(where: { $0.id == draft.id }) {
                choices.removeAll { $0.id == (bookmark.groupId ?? "__root__") }
            }
        }
        return choices
    }

    func refreshPromptChoices(filter: Bool) {
        guard let prompt else { return }
        if ["location", "to"].contains(prompt.field) {
            let choices = locationChoices()
            let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            let filtered = filter && !text.isEmpty ? choices.filter {
                $0.label.localizedCaseInsensitiveContains(text)
            } : choices
            self.prompt?.choices = filtered
            if let index = filtered.firstIndex(where: { $0.id == draft.location }) {
                self.prompt?.selectedChoice = index
            } else if !filtered.isEmpty {
                self.prompt?.selectedChoice = 0
                draft.location = filtered[0].id
            } else {
                self.prompt?.selectedChoice = 0
            }
            syncBookmarkPromptSteps()
        } else if ["path", "file"].contains(prompt.field) {
            refreshPathChoices()
        }
    }

    private func syncBookmarkPromptSteps() {
        guard let prompt, ["add", "edit", "move"].contains(prompt.command) else { return }
        let fields = promptFields(command: prompt.command)
        self.prompt?.total = fields.count
        self.prompt?.step = fields.firstIndex(of: prompt.field) ?? 0
    }

    func choosePromptOption(at index: Int, activate: Bool = false) {
        guard let prompt, !busy, prompt.choices.indices.contains(index) else { return }
        let choice = prompt.choices[index]
        self.prompt?.selectedChoice = index
        self.prompt?.error = nil
        if ["location", "to"].contains(prompt.field) {
            draft.location = choice.id
            syncBookmarkPromptSteps()
            if choice.id == "__new__" {
                showBookmarkField(command: prompt.command, field: "folder")
            } else if activate {
                advanceOrSubmitPrompt()
            } else if !inputText.isEmpty {
                setInput(.prompt, text: "")
                refreshPromptChoices(filter: false)
            }
            return
        }
        self.prompt?.choicesFocused = false
        setInput(.prompt, text: choice.label)
        captureDraft()
        if ["path", "file"].contains(prompt.field), choice.label.hasSuffix("/") { refreshPathChoices() }
    }

    func cyclePromptChoice(_ direction: Int) {
        guard let prompt, !busy, !prompt.choices.isEmpty else { return }
        let next = (prompt.selectedChoice + direction + prompt.choices.count) % prompt.choices.count
        self.prompt?.selectedChoice = next
        if ["location", "to"].contains(prompt.field) {
            draft.location = prompt.choices[next].id
            self.prompt?.error = nil
            syncBookmarkPromptSteps()
        }
    }

    static func checkedFolderName(_ value: String, in document: BookmarkDocument, excluding id: String? = nil) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else {
            throw BookmarkError.invalidData("文件夹名称不能为空，且不超过 60 字")
        }
        guard !document.groups.contains(where: { $0.id != id && $0.name == name }) else {
            throw BookmarkError.invalidData("已存在同名文件夹“\(name)”")
        }
        return name
    }

    static func checkedTitle(_ value: String) throws -> String {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120 else {
            throw BookmarkError.invalidData("标题不能为空，且不超过 120 字")
        }
        return title
    }

    func advanceOrSubmitPrompt() {
        guard let prompt, !busy else { return }
        captureDraft()
        switch prompt.command {
        case "add":
            switch prompt.field {
            case "url":
                do {
                    draft.url = try BookmarkURL.normalize(draft.url)
                    if !draft.titleEdited { draft.title = Self.suggestedTitle(for: draft.url) }
                    showBookmarkField(command: "add", field: "title")
                } catch {
                    self.prompt?.error = error.localizedDescription
                }
            case "title":
                do {
                    let candidate = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if candidate.isEmpty, !draft.titleEdited {
                        draft.title = Self.suggestedTitle(for: draft.url)
                    }
                    draft.title = try Self.checkedTitle(draft.title)
                    showBookmarkField(command: "add", field: "location")
                } catch {
                    self.prompt?.error = error.localizedDescription
                }
            case "location":
                guard prompt.choices.indices.contains(prompt.selectedChoice) else {
                    self.prompt?.error = "没有匹配的位置"
                    return
                }
                draft.location = prompt.choices[prompt.selectedChoice].id
                if draft.location == "__new__" {
                    showBookmarkField(command: "add", field: "folder")
                } else {
                    submitPrompt()
                }
            default:
                submitPrompt()
            }
        case "edit":
            if prompt.field == "location" {
                guard prompt.choices.indices.contains(prompt.selectedChoice) else {
                    self.prompt?.error = "没有匹配的位置"
                    return
                }
                draft.location = prompt.choices[prompt.selectedChoice].id
                if draft.location == "__new__" {
                    showBookmarkField(command: "edit", field: "folder")
                    return
                }
            }
            submitPrompt()
        case "move":
            if prompt.field == "to" {
                guard prompt.choices.indices.contains(prompt.selectedChoice) else {
                    self.prompt?.error = "没有匹配的位置"
                    return
                }
                draft.location = prompt.choices[prompt.selectedChoice].id
                if draft.location == "__new__" {
                    showBookmarkField(command: "move", field: "folder")
                    return
                }
            }
            submitPrompt()
        default:
            submitPrompt()
        }
    }

    func submitPrompt() {
        guard let prompt, !busy else { return }
        captureDraft()
        do {
            switch prompt.command {
            case "add", "edit":
                do { draft.url = try BookmarkURL.normalize(draft.url) }
                catch { showPromptError(field: "url", error: error); return }
                if !draft.titleEdited && draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    draft.title = Self.suggestedTitle(for: draft.url)
                }
                do { draft.title = try Self.checkedTitle(draft.title) }
                catch { showPromptError(field: "title", error: error); return }
                guard validatePromptLocation() else { return }
                if prompt.command == "add" { saveAddedBookmark(); return }
                let snapshot = draft
                guard let id = snapshot.id else { throw BookmarkError.invalidData("书签已不存在") }
                mutate("已保存“\(snapshot.title)”") { document in
                    guard document.bookmarks.contains(where: { $0.id == id }) else {
                        throw BookmarkError.invalidData("该书签已被外部删除，未提交内容已保留")
                    }
                    let newName = snapshot.location == "__new__"
                        ? try Self.checkedFolderName(snapshot.folderName, in: document) : nil
                    return try document.upsertBookmark(id: id, title: snapshot.title, url: snapshot.url,
                        groupID: snapshot.location == "__root__" || newName != nil ? nil : snapshot.location,
                        newGroupName: newName)
                }
            case "rename", "mkdir":
                let id = draft.id
                let name = try Self.checkedFolderName(draft.folderName, in: document, excluding: id)
                mutate(prompt.command == "rename" ? "已重命名为“\(name)”" : "已新建文件夹“\(name)”") { document in
                    let checked = try Self.checkedFolderName(name, in: document, excluding: id)
                    if let id { try document.renameGroup(id: id, name: checked); return id }
                    return try document.addGroup(name: checked)
                }
            case "move":
                guard validatePromptLocation() else { return }
                let snapshot = draft
                guard let id = snapshot.id else { throw BookmarkError.invalidData("书签已不存在") }
                mutate("已移动书签") { document in
                    let target: String?
                    if snapshot.location == "__new__" {
                        let name = try Self.checkedFolderName(snapshot.folderName, in: document)
                        target = try document.addGroup(name: name)
                    } else { target = snapshot.location == "__root__" ? nil : snapshot.location }
                    try document.moveBookmark(id: id, to: target)
                    return id
                }
            case "backup", "cd", "restore":
                let path = try resolvedPath(draft.path)
                runFileOperation(prompt.command, path: path)
            default: break
            }
        } catch { self.prompt?.error = error.localizedDescription }
    }

    func showPromptError(field: String, error: Error) {
        guard let command = prompt?.command else { return }
        showBookmarkField(command: command, field: field)
        prompt?.error = error.localizedDescription
    }

    func validatePromptLocation() -> Bool {
        if let prompt, ["location", "to"].contains(prompt.field), prompt.choices.isEmpty {
            self.prompt?.error = "没有匹配的位置"
            return false
        }
        if draft.location == "__new__" {
            do { _ = try Self.checkedFolderName(draft.folderName, in: document) }
            catch { showPromptError(field: "folder", error: error); return false }
        } else if draft.location != "__root__", !document.groups.contains(where: { $0.id == draft.location }) {
            showPromptError(field: prompt?.command == "move" ? "to" : "location",
                            error: BookmarkError.invalidData("请选择有效位置"))
            return false
        }
        return true
    }

    func saveAddedBookmark() {
        let snapshot = draft
        mutate("已添加“\(snapshot.title)”") { document in
            let newName = snapshot.location == "__new__"
                ? try Self.checkedFolderName(snapshot.folderName, in: document) : nil
            return try document.upsertBookmark(title: snapshot.title, url: snapshot.url,
                                               groupID: snapshot.location == "__root__" || newName != nil ? nil : snapshot.location,
                                               newGroupName: newName)
        }
    }

    func confirmPrompt() {
        guard let prompt, !prompt.acceptsText, !busy else { return }
        if prompt.command == "delete", let id = draft.id {
            let kind = draft.kind
            mutate("已删除“\(draft.title)”") { document in
                if kind == .folder { try document.deleteGroup(id: id) }
                else { try document.deleteBookmark(id: id) }
                return nil
            }
        }
    }

    func beginFilePrompt(_ command: String, path: String? = nil) {
        guard prompt == nil, !busy else { return }
        let value: String
        if let path { value = path }
        else if command == "backup" {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
            value = documents.appendingPathComponent("青蛙导航-Bookmarks-\(formatter.string(from: Date())).json").path
        } else { value = store.directory.path + "/" }
        draft = Draft(path: value)
        let hint = command == "restore"
            ? "Enter 恢复并替换全部书签与文件夹 · Tab 候选 · Esc 取消"
            : "Enter 提交 · Tab 候选 · Esc 取消"
        beginPrompt(command, field: command == "restore" ? "file" : "path", value: value, hint: hint)
    }

    func resolvedPath(_ raw: String) throws -> URL {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, let first = value.first, ["\"", "'"].contains(String(first)), value.last == first {
            value.removeFirst(); value.removeLast()
        }
        guard !value.isEmpty else { throw BookmarkError.invalidData("路径不能为空") }
        value = (value as NSString).expandingTildeInPath
        if (value as NSString).isAbsolutePath { return URL(fileURLWithPath: value).standardizedFileURL }
        return store.directory.appendingPathComponent(value).standardizedFileURL
    }

    func refreshPathChoices() {
        guard let prompt, ["file", "path"].contains(prompt.field) else { return }
        completionTask?.cancel()
        completionGeneration &+= 1
        let generation = completionGeneration
        let text = inputText
        let command = prompt.command
        let directory = store.directory
        self.prompt?.choices = []
        self.prompt?.selectedChoice = 0
        completionTask = Task { [weak self] in
            let choices = await Task.detached(priority: .userInitiated) {
                Self.pathChoices(text: text, command: command, base: directory)
            }.value
            guard let self, !Task.isCancelled, self.completionGeneration == generation,
                  self.inputText == text, self.prompt?.command == command else { return }
            self.prompt?.choices = choices
            self.prompt?.selectedChoice = 0
        }
    }

    nonisolated static func pathChoices(text: String, command: String, base: URL) -> [TerminalChoice] {
        let expanded = (text as NSString).expandingTildeInPath
        let absolute = (expanded as NSString).isAbsolutePath ? expanded : base.appendingPathComponent(expanded).path
        let typed = URL(fileURLWithPath: absolute)
        let rawName = (text as NSString).lastPathComponent
        let full = typed.standardizedFileURL
        let trailingSlash = text.hasSuffix("/") || text.isEmpty
        // 单独输入的 . / .. 表示“列出该目录”，不能在标准化后当作名字前缀。
        let listsTypedDirectory = trailingSlash || rawName == "." || rawName == ".."
        let parent = listsTypedDirectory ? full : full.deletingLastPathComponent()
        let prefix = listsTypedDirectory ? "" : full.lastPathComponent
        let customDirectory = command == "commands-directory"
        let foldedPrefix = prefix.lowercased()
        guard let urls = try? FileManager.default.contentsOfDirectory(at: parent,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: prefix.hasPrefix(".") ? [] : [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { url -> TerminalChoice? in
            let matches = customDirectory ? url.lastPathComponent.lowercased().hasPrefix(foldedPrefix)
                : url.lastPathComponent.localizedCaseInsensitiveContains(prefix)
            guard prefix.isEmpty || matches,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else { return nil }
            let isDirectory = values.isDirectory == true
            guard isDirectory || (!["cd", "commands-directory"].contains(command) && values.isRegularFile == true && url.pathExtension.lowercased() == "json") else { return nil }
            let value = url.standardizedFileURL.path + (isDirectory ? "/" : "")
            return TerminalChoice(id: value, label: value, detail: isDirectory ? "目录" : "JSON")
        }.sorted { lhs, rhs in
            if lhs.label.hasSuffix("/") != rhs.label.hasSuffix("/") { return lhs.label.hasSuffix("/") }
            return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
        }
    }

    func beginEdgeImport(path: String?) {
        guard prompt == nil, !busy else { return }
        let root: URL
        if let path {
            do { root = try resolvedPath(path) }
            catch { commandError(error.localizedDescription); return }
        } else {
            root = EdgeBookmarks.defaultDataRoot
        }
        runEdgeImport(root: root)
    }

    func runEdgeImport(root: URL) {
        guard !busy else { return }
        operationActive = true
        busy = true
        buffer = .job
        bufferOffset = 0
        job = TerminalJob(title: "import edge", status: .running, lines: [
            makeEntry(":import edge \(root.path)", .command),
            makeEntry("正在读取 Edge 收藏夹…", .info)
        ])
        Task { [self] in
            do {
                let payload = try await Task.detached(priority: .userInitiated) {
                    try EdgeBookmarks.load(from: root)
                }.value
                var summary = EdgeImportSummary()
                try await store.apply { summary = try $0.importEdge(payload) }
                let message = summary.inserted == 0 && summary.groups == 0
                    ? "无新增内容（重复 \(summary.duplicates) 条，不支持 \(summary.unsupported) 条）"
                    : "已导入 \(summary.inserted) 条书签、\(summary.groups) 个文件夹（跳过重复 \(summary.duplicates) 条，不支持 \(summary.unsupported) 条）"
                query = ""
                selectedIndex = 0
                scrollIndex = 0
                isOrganizing = false
                rebuildItems()
                job?.status = .success
                job?.lines.append(makeEntry(message, .success))
                appendLog(message, .success)
            } catch {
                job?.status = .failure
                job?.lines.append(makeEntry(error.localizedDescription, .error))
                appendLog(error.localizedDescription, .error)
            }
            operationActive = false
            busy = store.isBusy
            rebuildSettings()
        }
    }

    func runFileOperation(_ command: String, path: URL) {
        guard !busy else { return }
        operationActive = true
        busy = true
        buffer = .job
        bufferOffset = 0
        job = TerminalJob(title: command, status: .running, lines: [
            makeEntry(":\(command) \(path.path)", .command),
            makeEntry(command == "backup" ? "正在导出备份…" : "正在读取并校验数据…", .info)
        ])
        Task { [self] in
            do {
                let message: String
                switch command {
                case "backup":
                    try await store.exportBackup(to: path)
                    message = "已导出备份至 \(path.path)"
                case "restore":
                    try await store.restoreBackup(from: path)
                    message = "已恢复 \(document.bookmarks.count) 条书签、\(document.groups.count) 个文件夹"
                default:
                    try await store.switchDirectory(path)
                    message = "已切换数据目录至 \(store.directory.path)"
                }
                finishPrompt()
                if command != "backup" { query = ""; selectedIndex = 0; scrollIndex = 0; isOrganizing = false }
                rebuildItems()
                job?.status = .success
                job?.lines.append(makeEntry(message, .success))
                appendLog(message, .success)
            } catch {
                prompt?.error = error.localizedDescription
                job?.status = .failure
                job?.lines.append(makeEntry(error.localizedDescription, .error))
                appendLog(error.localizedDescription, .error)
            }
            operationActive = false
            busy = store.isBusy
            rebuildSettings()
        }
    }
}
