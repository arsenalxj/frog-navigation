import AppKit
import FrogCore
import FrogIcons
import Combine
import SwiftUI

enum LaunchItem: Identifiable, Equatable {
    case bookmark(Bookmark)
    case folder(BookmarkGroup)
    case add

    var id: String {
        switch self {
        case .bookmark(let value): return value.id
        case .folder(let value): return value.id
        case .add: return "__add__"
        }
    }
    var title: String {
        switch self {
        case .bookmark(let value): return value.title
        case .folder(let value): return value.name
        case .add: return "添加书签"
        }
    }
    var movable: Bool {
        switch self { case .bookmark, .folder: return true; default: return false }
    }
}

extension LauncherModel {
    func pointerDown(at point: CGPoint) {
        longPressTask?.cancel()
        pointerSource = nil; pointerStart = nil
        pointerDidDrag = false; pointerDidLongPress = false; suppressActivation = false
        guard visible, !modalVisible, !searching, !store.isBusy else { return }
        let scope = folderID == nil ? "root" : "folder"
        guard let source = activeItems.first(where: { item in
            item.movable && frames["\(scope)::\(item.id)"]?.contains(point) == true
        }) else { return }
        pointerSource = source; pointerStart = point
        longPressTask = Task {
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard pointerSource?.id == source.id, !pointerDidDrag, visible, !modalVisible else { return }
            pointerDidLongPress = true; suppressActivation = true
            editing = true; selection = source.id
        }
    }

    @discardableResult
    func pointerDragged(to point: CGPoint) -> Bool {
        guard let source = pointerSource, let start = pointerStart else { return false }
        if !pointerDidDrag {
            guard hypot(point.x - start.x, point.y - start.y) >= 6 else { return false }
            longPressTask?.cancel()
            pointerDidDrag = true; suppressActivation = true
            drag(source, point: point)
            if dragItem != nil { Diagnostics.emit("drag_started", details: ["scope": folderID == nil ? "root" : "folder"]) }
        } else if let item = dragItem { drag(item, point: point) }
        return pointerDidDrag
    }

    @discardableResult
    func pointerUp(at point: CGPoint) -> Bool {
        longPressTask?.cancel()
        let handled = pointerDidDrag || pointerDidLongPress
        if dragItem != nil {
            Diagnostics.emit("drag_dropped", details: ["scope": folderID == nil ? "root" : "folder"])
            finishDrag(point: point)
        }
        pointerSource = nil; pointerStart = nil; pointerDidDrag = false; pointerDidLongPress = false
        if handled {
            // 同一个 mouseUp 仍需交给 NSButton 结束按压，但不能再次执行点击打开。
            DispatchQueue.main.async { [weak self] in self?.suppressActivation = false }
        } else { suppressActivation = false }
        return handled
    }

    func drag(_ item: LaunchItem, point: CGPoint) {
        guard item.movable, !searching, !modalVisible, !store.isBusy else { return }
        if dragItem == nil {
            dragOriginal = store.document; dragDocument = store.document
            dragOriginalFolder = folderID; dragItem = item
            editing = true; selection = nil
        }
        guard dragItem?.id == item.id else { return }
        dragPoint = point
        if folderID != nil, !folderFrame.insetBy(dx: -25, dy: -25).contains(point) {
            if case .bookmark(let bookmark) = item {
                updateDrag { try $0.moveBookmark(id: bookmark.id, to: nil) }
                withAnimation(animation) { folderID = nil; folderPage = 0 }
                clearHover()
            }
        }
        updateEdge(point)
        let scope = folderID == nil ? "root" : "folder"
        let activeIDs = Set(activeItems.filter { $0.movable && $0.id != item.id }.map(\.id))
        let candidates = frames.filter {
            $0.key.hasPrefix(scope + "::") && activeIDs.contains(String($0.key.dropFirst(scope.count + 2)))
        }
        guard let pair = candidates.first(where: { $0.value.contains(point) }) else { clearHover(); return }
        let targetID = String(pair.key.dropFirst(scope.count + 2))
        guard targetID != "__add__" else { clearHover(); return }
        let rect = pair.value
        let mayMerge = folderID == nil && item.isBookmark && mergeHitRect(rect).contains(point)
        if mayMerge {
            if hoverID != targetID {
                clearHover(); hoverID = targetID; hoverPage = activePage
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(550))
                    guard !Task.isCancelled, hoverID == targetID, dragItem != nil else { return }
                    guard validMergeTarget(targetID, source: item, point: dragPoint) else { clearHover(); return }
                    withAnimation(animation) { mergeTarget = targetID }
                }
            }
            return
        }
        clearHover()
        let before = point.x < rect.midX
        updateDrag { data in
            if let groupID = self.folderID {
                var ids = data.bookmarks(in: groupID).map(\.id)
                guard ids.contains(item.id), let target = ids.firstIndex(of: targetID) else { return }
                let current = ids.firstIndex(of: item.id)!
                let destination = target + (before ? 0 : 1)
                if destination == current || destination == current + 1 { return }
                ids.removeAll { $0 == item.id }
                guard let adjusted = ids.firstIndex(of: targetID) else { return }
                ids.insert(item.id, at: adjusted + (before ? 0 : 1))
                try data.reorderGroup(id: groupID, bookmarkIDs: ids)
            } else {
                var ids = data.rootItems.map(\.id)
                guard ids.contains(item.id), let target = ids.firstIndex(of: targetID) else { return }
                let current = ids.firstIndex(of: item.id)!
                let destination = target + (before ? 0 : 1)
                if destination == current || destination == current + 1 { return }
                ids.removeAll { $0 == item.id }
                guard let adjusted = ids.firstIndex(of: targetID) else { return }
                ids.insert(item.id, at: adjusted + (before ? 0 : 1))
                try data.reorderRoot(ids: ids)
            }
        }
    }

    private func updateDrag(_ action: (inout BookmarkDocument) throws -> Void) {
        guard var next = dragDocument else { return }
        do {
            try action(&next)
            if next != dragDocument { withAnimation(animation) { dragDocument = next } }
        } catch { notify(error.localizedDescription); cancelDrag() }
    }

    private func mergeHitRect(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.midX - metrics.icon * 0.36, y: frame.minY + 2,
               width: metrics.icon * 0.72, height: metrics.icon * 0.80)
    }

    private func validMergeTarget(_ target: String, source: LaunchItem, point: CGPoint) -> Bool {
        guard source.isBookmark, folderID == nil, !searching,
              hoverID == target, hoverPage == activePage,
              activeItems.contains(where: { $0.id == target && $0.id != source.id && $0.movable }),
              let frame = frames["root::\(target)"] else { return false }
        return frame.contains(point) && mergeHitRect(frame).contains(point)
    }

    func finishDrag(point: CGPoint) {
        guard let item = dragItem, var next = dragDocument, let original = dragOriginal else { return }
        guard CGRect(origin: .zero, size: metrics.size).contains(point) else { cancelDrag(); return }
        var newFolderID: String?
        do {
            if let target = mergeTarget, validMergeTarget(target, source: item, point: point),
               case .bookmark(let source) = item {
                if next.groups.contains(where: { $0.id == target }) {
                    try next.moveBookmark(id: source.id, to: target)
                } else if next.bookmarks.contains(where: { $0.id == target }) {
                    newFolderID = try next.mergeBookmarks(sourceID: source.id, targetID: target)
                }
            } else {
                let scope = folderID == nil ? "root" : "folder"
                let activeIDs = Set(activeItems.map(\.id))
                let target = frames.first {
                    $0.key.hasPrefix(scope + "::") && $0.value.contains(point)
                        && activeIDs.contains(String($0.key.dropFirst(scope.count + 2)))
                }
                let isBlank = target == nil || target!.key.hasSuffix("::__add__")
                let bounds = folderID == nil ? CGRect(x: metrics.centerX - metrics.width / 2, y: metrics.top, width: metrics.width, height: metrics.height) : folderFrame
                if isBlank, bounds.contains(point) {
                    let pageIDs = activeItems.filter { $0.movable && $0.id != item.id }.map(\.id)
                    if let group = folderID {
                        var ids = next.bookmarks(in: group).map(\.id)
                        ids.removeAll { $0 == item.id }
                        let insertion = pageIDs.last.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? ids.count
                        ids.insert(item.id, at: insertion)
                        try next.reorderGroup(id: group, bookmarkIDs: ids)
                    } else {
                        var ids = next.rootItems.map(\.id)
                        ids.removeAll { $0 == item.id }
                        let insertion = pageIDs.last.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? ids.count
                        ids.insert(item.id, at: insertion)
                        try next.reorderRoot(ids: ids)
                    }
                }
            }
        } catch { notify(error.localizedDescription); cancelDrag(); return }
        clearDragState()
        guard next != original else { return }
        let result = next
        Task {
            do {
                try await store.apply { data in
                    guard data == original else { throw BookmarkError.conflict }
                    data = result
                }
                if let id = newFolderID, let group = store.document.groups.first(where: { $0.id == id }) {
                    openFolder(group); rename(group)
                }
            } catch { notify(error.localizedDescription) }
        }
    }

    func cancelDrag() {
        longPressTask?.cancel(); pointerSource = nil; pointerStart = nil
        if dragItem != nil, let originalFolder = dragOriginalFolder,
           store.document.groups.contains(where: { $0.id == originalFolder }) { folderID = originalFolder }
        clearDragState()
    }

    private func clearDragState() {
        clearHover(); edgeTask?.cancel(); edgeTask = nil; edgeDirection = 0
        dragItem = nil; dragDocument = nil; dragOriginal = nil; dragOriginalFolder = nil
    }

    private func clearHover() {
        hoverTask?.cancel(); hoverTask = nil; hoverID = nil; hoverPage = nil; mergeTarget = nil
    }

    private func updateEdge(_ point: CGPoint) {
        let bounds = folderID == nil ? CGRect(origin: .zero, size: metrics.size) : folderFrame
        let direction = point.x < bounds.minX + 55 ? -1 : (point.x > bounds.maxX - 55 ? 1 : 0)
        guard direction != edgeDirection else { return }
        edgeTask?.cancel(); edgeDirection = direction
        guard direction != 0 else { return }
        edgeTask = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                guard dragItem != nil else { return }
                clearHover()
                changePage(direction)
            }
        }
    }
}

private extension LaunchItem {
    var isBookmark: Bool { if case .bookmark = self { return true }; return false }
}

struct BookmarkDraft {
    var id: String?
    var url = ""
    var title = ""
    var location = "__root__"
    var newFolderName = ""
    var error: String?
}

struct GridMetrics: Equatable {
    let size: CGSize
    var dockInsets = DockInsets()
    var usableWidth: CGFloat { max(320, size.width - dockInsets.left - dockInsets.right) }
    var usableHeight: CGFloat { size.height - dockInsets.bottom }
    var centerX: CGFloat { dockInsets.left + usableWidth / 2 }
    var columns: Int { min(7, max(4, Int(usableWidth / 170))) }
    var rows: Int { min(5, max(2, Int(height / 130))) }
    var capacity: Int { columns * rows }
    var width: CGFloat { min(usableWidth - 100, usableWidth * 0.86) }
    var top: CGFloat { max(105, size.height * 0.12) }
    var height: CGFloat { max(160, size.height - top - max(124, dockInsets.bottom + 50)) }
    var dotsY: CGFloat { size.height - max(109, dockInsets.bottom + 26) }
    var icon: CGFloat { min(100, max(48, min(usableWidth / 18, cellHeight - 48))) }
    var cellWidth: CGFloat { width / CGFloat(columns) }
    var cellHeight: CGFloat { height / CGFloat(rows) }
}

struct DockInsets: Equatable {
    var left: CGFloat = 0
    var right: CGFloat = 0
    var bottom: CGFloat = 0
}

struct PageWindow: Equatable {
    let current: Int
    let indices: Range<Int>
    init(requestedPage: Int, pageCount: Int) {
        current = min(max(0, requestedPage), max(0, pageCount - 1))
        indices = pageCount > 0 ? max(0, current - 1)..<min(pageCount, current + 2) : 0..<0
    }
}

@MainActor
final class LauncherModel: ObservableObject {
    let store: BookmarkStore
    let icons: IconStore
    let login = LoginItemController()
    let hotKey: GlobalHotKeyController?
    let hotCorner: HotCornerController?
    let finderJump: FinderJumpController?
    let isolated: Bool
    @Published var visible = false
    @Published var presented = false
    @Published var query = ""
    @Published var rootPage: Int
    @Published var folderID: String?
    @Published var folderPage = 0
    @Published var searchPage = 0
    @Published var selection: String?
    @Published var editing = false
    @Published var showSettings = false
    @Published var showEditor = false
    @Published var savingDraft = false
    @Published var draft = BookmarkDraft()
    @Published var deleteTarget: LaunchItem?
    @Published var renamingID: String?
    @Published var renameText = ""
    @Published var renameError: String?
    @Published var toast: String?
    @Published var focusRequest = 0
    @Published var pageOffset: CGFloat = 0
    @Published var wallpaper: NSImage?
    @Published var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @Published var reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    @Published var dragItem: LaunchItem?
    @Published var dragPoint = CGPoint.zero
    @Published var dragDocument: BookmarkDocument?
    @Published var mergeTarget: String?
    @Published var metrics = GridMetrics(size: CGSize(width: 1440, height: 900))
    var frames: [String: CGRect] = [:]
    var folderFrame = CGRect.zero
    var folderOrigin = CGPoint(x: 0.5, y: 0.5)
    var dismissWindow: (() -> Void)?
    var withSystemPanel: ((Bool) -> Void)?
    private var hoverID: String?
    private var hoverPage: Int?
    private var hoverTask: Task<Void, Never>?
    private var edgeTask: Task<Void, Never>?
    private var edgeDirection = 0
    private var toastTask: Task<Void, Never>?
    private var dragOriginal: BookmarkDocument?
    private var dragOriginalFolder: String?
    private var pointerSource: LaunchItem?
    private var pointerStart: CGPoint?
    private var pointerDidDrag = false
    private var pointerDidLongPress = false
    private var suppressActivation = false
    private var longPressTask: Task<Void, Never>?
    private var scrollFinish: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var scrollTotal: CGFloat = 0
    private var scrollStartPage = 0
    private var handlingScroll = false

    init(store: BookmarkStore, icons: IconStore, isolated: Bool = false, hotKey: GlobalHotKeyController? = nil,
         hotCorner: HotCornerController? = nil, finderJump: FinderJumpController? = nil) {
        self.store = store; self.icons = icons; self.isolated = isolated
        self.hotKey = hotKey
        self.hotCorner = hotCorner
        self.finderJump = finderJump
        rootPage = isolated ? 0 : UserDefaults.standard.integer(forKey: "launcherRootPage")
        store.$document.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.documentChanged() }
        }.store(in: &subscriptions)
    }

    var document: BookmarkDocument { dragDocument ?? store.document }
    var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var modalVisible: Bool { showSettings || showEditor || deleteTarget != nil || renamingID != nil }
    var renameFocusToken: Int? {
        guard let renamingID else { return nil }
        if renamingID == folderID, showEditor || showSettings || deleteTarget != nil { return nil }
        return focusRequest
    }
    var editorFocusToken: Int? {
        guard showEditor, deleteTarget == nil,
              renamingID == nil || renamingID == folderID else { return nil }
        return focusRequest
    }
    var activePage: Int { searching ? searchPage : (folderID == nil ? rootPage : folderPage) }
    var activePageCount: Int { searching ? searchPages.count : (folderID == nil ? rootPages.count : folderPages.count) }
    var activeColumns: Int { folderID != nil && !searching ? 3 : metrics.columns }
    var activeItems: [LaunchItem] {
        let pages = searching ? searchPages : (folderID == nil ? rootPages : folderPages)
        return pages[min(max(0, activePage), pages.count - 1)]
    }
    var rootPages: [[LaunchItem]] {
        let items = document.rootItems.map { item -> LaunchItem in
            switch item { case .bookmark(let value): return .bookmark(value); case .group(let value): return .folder(value) }
        }
        let pages = chunks(items, size: metrics.capacity)
        return pages.isEmpty ? [[]] : pages
    }
    var folderPages: [[LaunchItem]] {
        guard let folderID else { return [[.add]] }
        let items = document.bookmarks(in: folderID).map(LaunchItem.bookmark) + [.add]
        return chunks(items, size: 9)
    }
    var searchPages: [[LaunchItem]] {
        let pages = chunks(document.search(query).map(LaunchItem.bookmark), size: metrics.capacity)
        return pages.isEmpty ? [[]] : pages
    }
    var animation: Animation? { reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.32, dampingFraction: 0.85) }

    func chunks(_ values: [LaunchItem], size: Int) -> [[LaunchItem]] {
        stride(from: 0, to: values.count, by: size).map { Array(values[$0..<min($0 + size, values.count)]) }
    }
    func layoutChanged(_ size: CGSize) {
        guard metrics.size != size else { return }
        cancelDrag()
        metrics = GridMetrics(size: size, dockInsets: metrics.dockInsets)
        clampPages()
    }
    func screenChanged(size: CGSize, dockInsets: DockInsets) {
        cancelDrag()
        metrics = GridMetrics(size: size, dockInsets: dockInsets)
        clampPages()
    }
    func documentChanged() {
        if let original = dragOriginal, original != store.document { cancelDrag() }
        if let folderID, !store.document.groups.contains(where: { $0.id == folderID }) { self.folderID = nil }
        if let selection, !store.document.bookmarks.contains(where: { $0.id == selection }) && !store.document.groups.contains(where: { $0.id == selection }) { self.selection = nil }
        clampPages()
    }
    func clampPages() {
        rootPage = min(max(0, rootPage), rootPages.count - 1)
        folderPage = min(max(0, folderPage), folderPages.count - 1)
        searchPage = min(max(0, searchPage), searchPages.count - 1)
    }
    func queryChanged() {
        searchPage = 0; selection = nil; cancelDrag(); pageOffset = 0
    }
    func setPage(_ value: Int, animated: Bool = true) {
        clearHover()
        let value = min(max(value, 0), activePageCount - 1)
        withAnimation(animated ? animation : nil) {
            if searching { searchPage = value }
            else if folderID != nil { folderPage = value }
            else { rootPage = value }
            pageOffset = 0
        }
        if !isolated { UserDefaults.standard.set(rootPage, forKey: "launcherRootPage") }
        selection = nil
    }
    func changePage(_ delta: Int) { setPage(activePage + delta) }
    func openFolder(_ group: BookmarkGroup) {
        guard dragItem == nil else { return }
        if let frame = frames["root::\(group.id)"] {
            folderOrigin = CGPoint(x: frame.midX / metrics.size.width, y: frame.midY / metrics.size.height)
        }
        withAnimation(animation) { folderID = group.id; folderPage = 0; selection = nil; pageOffset = 0 }
    }
    func closeFolder() { withAnimation(animation) { folderID = nil; folderPage = 0; selection = nil; pageOffset = 0 } }
    func backgroundClicked() {
        if dragItem != nil { cancelDrag(); return }
        if renamingID != nil && renamingID == folderID { saveRename(); return }
        if modalVisible { return }
        if editing { editing = false; return }
        if folderID != nil { closeFolder(); return }
        dismissWindow?()
    }
    func escape() {
        if dragItem != nil { cancelDrag(); return }
        // 独立重命名面板位于所有弹窗之上；文件夹行内重命名位于弹窗之下。
        if renamingID != nil && renamingID != folderID { renamingID = nil; focusRequest += 1; return }
        if deleteTarget != nil { deleteTarget = nil; focusRequest += 1; return }
        if showEditor { showEditor = false; focusRequest += 1; return }
        if showSettings { showSettings = false; focusRequest += 1; return }
        if renamingID != nil { renamingID = nil; focusRequest += 1; return }
        if editing { editing = false; return }
        if searching { query = ""; focusRequest += 1; return }
        if folderID != nil { closeFolder(); return }
        dismissWindow?()
    }
    func activate(_ item: LaunchItem) {
        guard dragItem == nil, !suppressActivation else { return }
        switch item {
        case .bookmark(let bookmark):
            if editing { selection = item.id } else { openURL(bookmark.url) }
        case .folder(let group): openFolder(group)
        case .add: addBookmark()
        }
    }
    func openURL(_ value: String) {
        guard let url = URL(string: value), BookmarkURL.isValid(value) else { notify("无法打开此网址，请编辑后重试。"); return }
        if NSWorkspace.shared.open(url) { dismissWindow?() }
        else { notify("默认浏览器未能打开此网址，请检查系统默认浏览器后重试。") }
    }
    func submitSearch() {
        guard !modalVisible else { return }
        let items = activeItems.filter { $0.movable }
        if let item = items.first(where: { $0.id == selection }) ?? items.first { activate(item); return }
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if let url = try? BookmarkURL.normalize(value) { openURL(url) }
        else {
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: value)]
            if let value = components.url?.absoluteString { openURL(value) }
        }
    }
    func select(direction: Int) {
        let items = activeItems
        guard !items.isEmpty else { return }
        if let index = items.firstIndex(where: { $0.id == selection }) {
            let next = index + direction
            if next < 0, activePage > 0 { changePage(-1); selection = activeItems.last?.id }
            else if next >= items.count, activePage < activePageCount - 1 { changePage(1); selection = activeItems.first?.id }
            else { selection = items[min(max(0, next), items.count - 1)].id }
        } else { selection = items.first?.id }
    }
    func addBookmark() {
        if draft.id != nil || (draft.url.isEmpty && draft.title.isEmpty) {
            draft = BookmarkDraft(location: searching ? "__root__" : (folderID ?? "__root__"))
        }
        editing = false; showEditor = true
    }
    func edit(_ bookmark: Bookmark) {
        draft = BookmarkDraft(id: bookmark.id, url: bookmark.url, title: bookmark.title, location: bookmark.groupId ?? "__root__")
        editing = false; showEditor = true
    }
    func saveDraft() {
        guard !savingDraft else { return }
        savingDraft = true
        let snapshot = draft
        Task {
            defer { savingDraft = false }
            do {
                let normalized = try BookmarkURL.normalize(snapshot.url)
                let title = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, title.count <= 120 else { throw BookmarkError.invalidData("标题不能为空，且不能超过 120 个字符。") }
                var savedID = ""
                try await store.apply { data in
                    savedID = try data.upsertBookmark(id: snapshot.id, title: title, url: normalized,
                                                     groupID: snapshot.location.hasPrefix("__") ? nil : snapshot.location,
                                                     newGroupName: snapshot.location == "__new__" ? snapshot.newFolderName : nil)
                }
                showEditor = false; draft = BookmarkDraft(); selection = savedID
                revealBookmark(savedID)
                focusRequest += 1
                notify(snapshot.id == nil ? "书签已添加" : "书签已保存")
            } catch { draft.error = error.localizedDescription }
        }
    }

    private func revealBookmark(_ id: String) {
        guard let bookmark = store.document.bookmarks.first(where: { $0.id == id }) else { return }
        query = ""; selection = id
        if let group = bookmark.groupId {
            folderID = group
            folderPage = (store.document.bookmarks(in: group).firstIndex(where: { $0.id == id }) ?? 0) / 9
        } else {
            folderID = nil
            if let index = store.document.rootItems.firstIndex(where: { $0.id == id }) {
                rootPage = index / metrics.capacity
            }
            if !isolated { UserDefaults.standard.set(rootPage, forKey: "launcherRootPage") }
        }
    }
    func requestDelete(_ item: LaunchItem) {
        guard !suppressActivation else { return }
        if case .folder(let group) = item, !store.document.bookmarks(in: group.id).isEmpty {
            notify("请先移出或删除文件夹中的书签，再删除文件夹。")
            return
        }
        deleteTarget = item
    }
    func confirmDelete() {
        guard let target = deleteTarget else { return }
        perform({ data in
            switch target {
            case .bookmark(let value): try data.deleteBookmark(id: value.id)
            case .folder(let value): try data.deleteGroup(id: value.id)
            default: break
            }
        }, success: { self.deleteTarget = nil; self.notify("已删除“\(target.title)”") })
    }
    func rename(_ group: BookmarkGroup) {
        if folderID != group.id { openFolder(group) }
        renamingID = group.id; renameText = group.name; renameError = nil
    }
    func saveRename() {
        guard let id = renamingID else { return }
        let name = renameText
        Task {
            do { try await store.apply { try $0.renameGroup(id: id, name: name) }; renamingID = nil }
            catch { renameError = error.localizedDescription }
        }
    }
    func move(_ bookmark: Bookmark, to groupID: String?) {
        perform { try $0.moveBookmark(id: bookmark.id, to: groupID) }
    }
    func copy(_ bookmark: Bookmark) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(bookmark.url, forType: .string)
        notify("链接已复制")
    }
    func refreshIcon(_ bookmark: Bookmark) { Task { await icons.load(bookmark.url, force: true) } }
    func perform(_ mutation: @escaping (inout BookmarkDocument) throws -> Void, success: (() -> Void)? = nil) {
        Task {
            do { try await store.apply(mutation); success?() }
            catch { notify(error.localizedDescription) }
        }
    }
    func notify(_ message: String) {
        toastTask?.cancel(); toast = message
        toastTask = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { withAnimation { toast = nil } } }
    }
    func resetAfterReplacingData() {
        cancelDrag(); rootPage = 0; folderID = nil; folderPage = 0; query = ""; selection = nil
        editing = false; draft = BookmarkDraft(); showEditor = false; deleteTarget = nil; renamingID = nil
        if !isolated { UserDefaults.standard.set(0, forKey: "launcherRootPage") }
    }
    func didHide() {
        visible = false; presented = false; editing = false; cancelDrag(); pageOffset = 0
        suppressActivation = false; pointerDidDrag = false; pointerDidLongPress = false
        query = ""; folderID = nil; folderPage = 0; selection = nil
        scrollFinish?.cancel(); handlingScroll = false; scrollTotal = 0
        icons.trimMemory()
    }

    // A scroll sequence owns exactly one page transition; momentum must not trigger a second page.
    func scroll(_ event: NSEvent) {
        guard visible, !modalVisible, dragItem == nil, activePageCount > 1 else { return }
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || handlingScroll else { return }
        if !event.momentumPhase.isEmpty { return }
        if !handlingScroll {
            handlingScroll = true; scrollStartPage = activePage; scrollTotal = 0
        }
        scrollFinish?.cancel()
        scrollTotal += event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 20)
        let width = folderID != nil && !searching ? min(620, metrics.usableWidth - 80) : metrics.size.width
        let atEnd = (scrollStartPage == 0 && scrollTotal > 0) || (scrollStartPage == activePageCount - 1 && scrollTotal < 0)
        pageOffset = reduceMotion ? 0 : max(-width, min(width, scrollTotal)) * (atEnd ? 0.22 : 1)
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { finishScroll(cancel: event.phase.contains(.cancelled)) }
        else { scrollFinish = Task { try? await Task.sleep(for: .milliseconds(140)); if !Task.isCancelled { finishScroll(cancel: false) } } }
    }
    private func finishScroll(cancel: Bool) {
        guard handlingScroll else { return }
        handlingScroll = false
        let threshold: CGFloat = folderID == nil ? 90 : 65
        let delta = !cancel && abs(scrollTotal) > threshold ? (scrollTotal < 0 ? 1 : -1) : 0
        setPage(scrollStartPage + delta); scrollTotal = 0
    }
}
