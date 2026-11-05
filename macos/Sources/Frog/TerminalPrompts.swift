import AppKit
import FrogCore

extension LauncherModel {
    func beginPrompt(_ command: String, step: Int = 0, total: Int = 0, field: String, value: String,
                     hint: String = "Enter 提交 · Esc 取消", acceptsText: Bool = true) {
        prompt = TerminalPrompt(command: command, step: step, total: total, field: field,
                                hint: hint, acceptsText: acceptsText)
        if command == "edit" {
            prompt?.context = field == "title" ? "网址：\(draft.url)" : "标题：\(draft.title ?? "")"
        }
        setInput(.prompt, text: value)
        refreshPromptChoices(filter: false)
    }

    func finishPrompt() {
        completionGeneration &+= 1
        completionTask?.cancel()
        completionTask = nil
        prompt = nil
        inputKind = nil
        draft = Draft()
    }

    func addBookmark() {
        guard prompt == nil, !busy else { return }
        buffer = nil
        draft = Draft(location: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (folderID ?? "__root__") : "__root__")
        beginPrompt("add", total: 3, field: "url", value: "", hint: "Enter 下一步 · Esc 取消")
    }

    func beginEdit(urlFirst: Bool = false) {
        guard prompt == nil, !busy, let bookmark = selectedBookmark() else { return }
        draft = Draft(id: bookmark.id, url: bookmark.url, title: bookmark.title,
                      location: bookmark.groupId ?? "__root__")
        beginPrompt("edit", step: urlFirst ? 1 : 0, total: 2, field: urlFirst ? "url" : "title",
                    value: urlFirst ? bookmark.url : bookmark.title,
                    hint: "Tab/Shift+Tab 切换字段 · Enter 保存全部 · Esc 取消")
    }

    func beginRename() {
        guard prompt == nil, !busy else { return }
        guard items.indices.contains(selectedIndex), items[selectedIndex].kind == .folder,
              let group = document.groups.first(where: { $0.id == items[selectedIndex].id }) else {
            appendLog("请选择文件夹。", .error)
            return
        }
        draft = Draft(id: group.id, kind: .folder, folderName: group.name)
        beginPrompt("rename", field: "name", value: group.name)
    }

    func beginMkdir() {
        guard prompt == nil, !busy else { return }
        draft = Draft()
        beginPrompt("mkdir", field: "name", value: "")
    }

    func beginMove() {
        guard prompt == nil, !busy, let bookmark = selectedBookmark() else { return }
        draft = Draft(id: bookmark.id, location: bookmark.groupId == nil ? "__new__" : "__root__")
        let options = locationChoices()
        draft.location = options.first?.id ?? "__new__"
        beginPrompt("move", field: "to", value: options.first?.label ?? "新建文件夹…",
                    hint: "Tab/上下选择 · Enter 移动 · Esc 取消")
    }

    func requestDeleteSelection() {
        guard prompt == nil, !busy, items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        guard item.kind != .add else { appendLog("添加入口不可删除。", .warning); return }
        if item.kind == .folder && document.bookmarks.contains(where: { $0.groupId == item.id }) {
            appendLog("请先移出或删除文件夹内的书签，再删除文件夹。", .error)
            return
        }
        draft = Draft(id: item.id, kind: item.kind, title: item.title)
        beginPrompt("delete", field: "confirm", value: "",
                    hint: "删除 “\(item.title)”？ y 删除 · N/Enter/Esc 取消", acceptsText: false)
    }

    func captureDraft() {
        guard let prompt else { return }
        switch prompt.field {
        case "title": draft.title = inputText
        case "url": draft.url = inputText
        case "name", "folder": draft.folderName = inputText
        case "path", "file": draft.path = inputText
        default: break
        }
    }

    func switchEditField() {
        guard prompt?.command == "edit", !busy else { return }
        captureDraft()
        let url = prompt?.field == "title"
        beginPrompt("edit", step: url ? 1 : 0, total: 2, field: url ? "url" : "title",
                    value: url ? draft.url : (draft.title ?? ""),
                    hint: "Tab/Shift+Tab 切换字段 · Enter 保存全部 · Esc 取消")
    }

    func previousPrompt() {
        guard let prompt, !busy else { return }
        captureDraft()
        if prompt.command == "add" {
            switch prompt.step {
            case 1:
                beginPrompt("add", total: 3, field: "url", value: draft.url, hint: "Enter 下一步 · Esc 取消")
            case 2:
                beginPrompt("add", step: 1, total: 3, field: "title", value: draft.title ?? "",
                            hint: "Enter 下一步 · Shift+Tab 返回 · Esc 取消")
            case 3: showLocation(command: "add")
            default: break
            }
        } else if prompt.command == "move", prompt.step == 1 { showLocation(command: "move") }
    }

    func showLocation(command: String) {
        let choices = locationChoices()
        let selected = choices.first(where: { $0.id == draft.location }) ?? choices.first
        draft.location = selected?.id ?? "__root__"
        beginPrompt(command, step: command == "add" ? 2 : 0, total: command == "add" ? 3 : 0,
                    field: command == "add" ? "location" : "to", value: selected?.label ?? "",
                    hint: "Tab/上下选择 · Shift+Tab 返回 · Enter 选择 · Esc 取消")
    }

    func locationChoices() -> [TerminalChoice] {
        var choices = [TerminalChoice(id: "__root__", label: "根目录")]
        choices += document.groups.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
            .map { TerminalChoice(id: $0.id, label: $0.name,
                                  detail: "\(document.bookmarks(in: $0.id).count) bookmarks") }
        choices.append(TerminalChoice(id: "__new__", label: "新建文件夹…", detail: "先命名，再原子保存"))
        if prompt?.command == "move" || draft.id != nil {
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
            self.prompt?.choices = filter && !text.isEmpty ? choices.filter {
                $0.label.localizedCaseInsensitiveContains(text)
            } : choices
            self.prompt?.selectedChoice = self.prompt?.choices.firstIndex { $0.id == draft.location } ?? 0
        } else if ["path", "file"].contains(prompt.field) {
            refreshPathChoices()
        }
    }

    func choosePromptOption(at index: Int) {
        guard let prompt, !busy, prompt.choices.indices.contains(index) else { return }
        let choice = prompt.choices[index]
        self.prompt?.selectedChoice = index
        self.prompt?.error = nil
        if ["location", "to"].contains(prompt.field) { draft.location = choice.id }
        setInput(.prompt, text: choice.label)
        captureDraft()
        if ["path", "file"].contains(prompt.field), choice.label.hasSuffix("/") { refreshPathChoices() }
    }

    func cyclePromptChoice(_ direction: Int) {
        guard let prompt, !busy, !prompt.choices.isEmpty else { return }
        let currentIsFilled = prompt.choices.indices.contains(prompt.selectedChoice)
            && prompt.choices[prompt.selectedChoice].label == inputText
        let index = currentIsFilled ? (prompt.selectedChoice + direction + prompt.choices.count) % prompt.choices.count
            : (direction < 0 ? prompt.choices.count - 1 : prompt.selectedChoice)
        choosePromptOption(at: index)
    }

    static func checkedFolderName(_ value: String, in document: BookmarkDocument, excluding id: String? = nil) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else {
            throw BookmarkError.invalidData("文件夹名称不能为空，且不能超过 60 字。")
        }
        guard !document.groups.contains(where: { $0.id != id && $0.name == name }) else {
            throw BookmarkError.invalidData("已存在同名文件夹 “\(name)”。")
        }
        return name
    }

    static func checkedTitle(_ value: String) throws -> String {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120 else { throw BookmarkError.invalidData("标题不能为空，且不能超过 120 字。") }
        return title
    }

    func submitPrompt() {
        guard let prompt, !busy else { return }
        captureDraft()
        do {
            switch prompt.command {
            case "add":
                switch prompt.step {
                case 0:
                    draft.url = try BookmarkURL.normalize(draft.url)
                    let title = draft.title ?? URL(string: draft.url)?.host ?? ""
                    draft.title = title
                    beginPrompt("add", step: 1, total: 3, field: "title", value: title,
                                hint: "Enter 下一步 · Shift+Tab 返回 · Esc 取消")
                case 1:
                    draft.title = try Self.checkedTitle(draft.title ?? "")
                    showLocation(command: "add")
                case 2:
                    guard prompt.choices.indices.contains(prompt.selectedChoice) else {
                        throw BookmarkError.invalidData("请选择一个有效位置。")
                    }
                    draft.location = prompt.choices[prompt.selectedChoice].id
                    if draft.location == "__new__" {
                        beginPrompt("add", step: 3, total: 4, field: "folder", value: draft.folderName,
                                    hint: "Enter 创建并添加 · Shift+Tab 返回 · Esc 取消")
                    } else { saveAddedBookmark() }
                default:
                    _ = try Self.checkedFolderName(draft.folderName, in: document)
                    saveAddedBookmark()
                }
            case "edit":
                let title: String
                do { title = try Self.checkedTitle(draft.title ?? "") }
                catch { showEditError(field: "title", error: error); return }
                let url: String
                do { url = try BookmarkURL.normalize(draft.url) }
                catch { showEditError(field: "url", error: error); return }
                guard let id = draft.id else { throw BookmarkError.invalidData("书签已不存在。") }
                mutate("已保存 “\(title)”") { document in
                    guard let bookmark = document.bookmarks.first(where: { $0.id == id }) else {
                        throw BookmarkError.invalidData("该书签已被外部删除；未提交输入仍保留。")
                    }
                    return try document.upsertBookmark(id: id, title: title, url: url, groupID: bookmark.groupId)
                }
            case "rename", "mkdir":
                let id = draft.id
                let name = try Self.checkedFolderName(draft.folderName, in: document, excluding: id)
                mutate(prompt.command == "rename" ? "已重命名为 “\(name)”" : "已创建文件夹 “\(name)”") { document in
                    let checked = try Self.checkedFolderName(name, in: document, excluding: id)
                    if let id { try document.renameGroup(id: id, name: checked); return id }
                    return try document.addGroup(name: checked)
                }
            case "move":
                if prompt.step == 0 {
                    guard prompt.choices.indices.contains(prompt.selectedChoice) else {
                        throw BookmarkError.invalidData("请选择一个有效目标。")
                    }
                    draft.location = prompt.choices[prompt.selectedChoice].id
                    if draft.location == "__new__" {
                        beginPrompt("move", step: 1, total: 2, field: "name", value: draft.folderName,
                                    hint: "Enter 创建并移动 · Shift+Tab 返回 · Esc 取消")
                        return
                    }
                } else { _ = try Self.checkedFolderName(draft.folderName, in: document) }
                let snapshot = draft
                guard let id = snapshot.id else { throw BookmarkError.invalidData("书签已不存在。") }
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

    func showEditError(field: String, error: Error) {
        if prompt?.field != field {
            beginPrompt("edit", step: field == "url" ? 1 : 0, total: 2, field: field,
                        value: field == "url" ? draft.url : (draft.title ?? ""),
                        hint: "Tab/Shift+Tab 切换字段 · Enter 保存全部 · Esc 取消")
        }
        prompt?.error = error.localizedDescription
    }

    func saveAddedBookmark() {
        let snapshot = draft
        mutate("已添加 “\(snapshot.title ?? "")”") { document in
            let newName = snapshot.location == "__new__"
                ? try Self.checkedFolderName(snapshot.folderName, in: document) : nil
            return try document.upsertBookmark(title: snapshot.title ?? "", url: snapshot.url,
                                               groupID: snapshot.location == "__root__" || newName != nil ? nil : snapshot.location,
                                               newGroupName: newName)
        }
    }

    func confirmPrompt() {
        guard let prompt, !prompt.acceptsText, !busy else { return }
        if prompt.command == "delete", let id = draft.id {
            let kind = draft.kind
            mutate("已删除 “\(draft.title ?? "")”") { document in
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
        beginPrompt(command, field: command == "restore" ? "file" : "path", value: value,
                    hint: command == "restore" ? "Enter 恢复并替换全部书签与文件夹 · Tab 补全 · Esc 取消" : "Enter 提交 · Tab/上下补全真实路径 · Esc 取消")
    }

    func resolvedPath(_ raw: String) throws -> URL {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, let first = value.first, ["\"", "'"].contains(String(first)), value.last == first {
            value.removeFirst(); value.removeLast()
        }
        guard !value.isEmpty else { throw BookmarkError.invalidData("路径不能为空。") }
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
        let full = URL(fileURLWithPath: absolute)
        let trailingSlash = text.hasSuffix("/") || text.isEmpty
        let parent = trailingSlash ? full : full.deletingLastPathComponent()
        let prefix = trailingSlash ? "" : full.lastPathComponent
        guard let urls = try? FileManager.default.contentsOfDirectory(at: parent,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { url -> TerminalChoice? in
            guard prefix.isEmpty || url.lastPathComponent.localizedCaseInsensitiveContains(prefix),
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else { return nil }
            let isDirectory = values.isDirectory == true
            guard isDirectory || (command != "cd" && values.isRegularFile == true && url.pathExtension.lowercased() == "json") else { return nil }
            let value = url.path + (isDirectory ? "/" : "")
            return TerminalChoice(id: value, label: value, detail: isDirectory ? "directory" : "JSON")
        }.sorted { lhs, rhs in
            if lhs.detail != rhs.detail { return lhs.detail == "directory" }
            return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
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
            makeEntry(command == "backup" ? "校验并导出当前数据…" : "读取并校验真实数据文件…", .info)
        ])
        Task { [self] in
            do {
                let message: String
                switch command {
                case "backup":
                    try await store.exportBackup(to: path)
                    message = "备份已保存至 \(path.path)"
                case "restore":
                    try await store.restoreBackup(from: path)
                    message = "已整体恢复 \(document.bookmarks.count) 条书签与 \(document.groups.count) 个文件夹；数据目录未改变。"
                default:
                    try await store.switchDirectory(path)
                    message = "数据目录：\(store.directory.path)；旧目录数据保留。"
                }
                finishPrompt()
                if command != "backup" { folderID = nil; query = ""; selectedIndex = 0; scrollIndex = 0; isOrganizing = false }
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
