import AppKit
import XCTest
import FrogCore
@testable import Frog

@MainActor
final class LauncherModelTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
        super.tearDown()
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Frog-Terminal-Tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    private func makeModel(_ document: BookmarkDocument = BookmarkDocument()) async throws -> LauncherModel {
        let directory = try directory()
        try document.encoded().write(to: directory.appendingPathComponent("bookmarks.json"))
        let store = BookmarkStore(directoryOverride: directory, persistDirectory: false)
        await store.load()
        let model = LauncherModel(store: store, isolated: true)
        model.readClipboardString = { nil }
        return model
    }

    private func fixture(count: Int) -> BookmarkDocument {
        BookmarkDocument(bookmarks: (0..<count).map { Bookmark(title: "书签 \($0)", url: "https://example.com/\($0)", order: $0) })
    }

    private func settle(_ condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "异步操作未在时限内完成")
    }

    private func saved(_ model: LauncherModel) throws -> BookmarkDocument {
        try BookmarkDocument.decode(Data(contentsOf: model.store.directory.appendingPathComponent("bookmarks.json")))
    }

    private func key(_ code: UInt16, _ text: String = "", modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }

    private func select(_ id: String, in model: LauncherModel) throws {
        model.selectItem(at: try XCTUnwrap(model.items.firstIndex { $0.id == id }))
    }

    private func choose(_ id: String, in model: LauncherModel) throws {
        model.choosePromptOption(at: try XCTUnwrap(model.prompt?.choices.firstIndex { $0.id == id }))
    }

    private func addThroughTitle(_ model: LauncherModel, url: String = "example.org", title: String = "新增书签") {
        model.addBookmark()
        model.updateInput(url)
        model.switchPromptField(1)
        model.updateInput(title)
        model.switchPromptField(1)
    }

    func testFolderRowsExpandInPlaceWithStableRootOrder() async throws {
        let group = BookmarkGroup(name: "工作", order: 30)
        let root = Bookmark(title: "根书签", url: "https://www.root.example:8443/path?query=value", order: 0)
        let child = Bookmark(title: "目录书签", url: "https://child.example", groupId: group.id)
        let model = try await makeModel(BookmarkDocument(groups: [group], bookmarks: [root, child]))
        XCTAssertEqual(model.items.map(\.kind), [.folder, .bookmark])
        XCTAssertEqual(model.items.map(\.id), [group.id, root.id])
        XCTAssertEqual(model.items[1].detail, "root.example:8443")
        XCTAssertEqual(model.items[1].url, root.url)
        XCTAssertEqual(model.visibleRowCount, 19)
        model.activateSelection()
        XCTAssertTrue(model.expandedGroupIDs.contains(group.id))
        XCTAssertEqual(model.items.map(\.kind), [.folder, .bookmark, .bookmark])
        XCTAssertEqual(model.items[1].id, child.id)
        XCTAssertEqual(model.items[1].depth, 1)
        XCTAssertEqual(model.items[2].id, root.id)
        XCTAssertEqual(model.items[2].depth, 0)
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.visibleRowCount, 19)
        model.toggleExpanded(group.id)
        XCTAssertFalse(model.expandedGroupIDs.contains(group.id))
        XCTAssertEqual(model.items.map(\.id), [group.id, root.id])
    }

    func testTabDoesNotToggleFolderAndArrowsDo() async throws {
        let group = BookmarkGroup(name: "工作")
        let child = Bookmark(title: "子项", url: "https://child.example", groupId: group.id)
        let model = try await makeModel(BookmarkDocument(groups: [group], bookmarks: [child]))
        _ = model.handleKey(try key(48, "\t"), isTextEditing: false)
        XCTAssertFalse(model.expandedGroupIDs.contains(group.id))
        _ = model.handleKey(try key(124), isTextEditing: false)
        XCTAssertTrue(model.expandedGroupIDs.contains(group.id))
        model.moveCursor(1)
        _ = model.handleKey(try key(123), isTextEditing: false)
        XCTAssertFalse(model.expandedGroupIDs.contains(group.id))
        XCTAssertEqual(model.items[model.selectedIndex].id, group.id)
    }

    func testEmptyRootHasNoVirtualRowAndExpandedFolderStaysEmpty() async throws {
        let empty = try await makeModel()
        XCTAssertTrue(empty.items.isEmpty)
        empty.activateSelection()
        XCTAssertNil(empty.prompt)
        empty.addBookmark()
        XCTAssertEqual(empty.prompt?.command, "add")
        let group = BookmarkGroup(name: "空文件夹")
        let model = try await makeModel(BookmarkDocument(groups: [group]))
        model.activateSelection()
        XCTAssertTrue(model.expandedGroupIDs.contains(group.id))
        XCTAssertEqual(model.items.map(\.kind), [.folder])
        model.addBookmark()
        model.updateInput("folder.example")
        model.switchPromptField(1)
        model.switchPromptField(1)
        try choose(group.id, in: model)
        model.submitInput()
        try await settle { !model.busy }
        XCTAssertEqual(try saved(model).bookmarks.first?.groupId, group.id)
    }

    func testAddRetainsAllDraftsWhenSteppingBackwardAndCancelsWithoutWriting() async throws {
        let model = try await makeModel()
        let original = try saved(model)
        addThroughTitle(model, title: "未提交标题")
        try choose("__new__", in: model)
        XCTAssertEqual(model.prompt?.field, "folder")
        model.updateInput("未提交文件夹")
        XCTAssertTrue(model.handleKey(try key(48, "\t", modifiers: .shift), isTextEditing: true))
        XCTAssertEqual(model.prompt?.field, "location")
        model.switchPromptField(1)
        XCTAssertEqual(model.prompt?.field, "folder")
        XCTAssertEqual(model.inputText, "未提交文件夹")
        _ = model.handleKey(try key(48, "\t", modifiers: .shift), isTextEditing: true)
        _ = model.handleKey(try key(48, "\t", modifiers: .shift), isTextEditing: true)
        XCTAssertEqual(model.inputText, "未提交标题")
        _ = model.handleKey(try key(48, "\t", modifiers: .shift), isTextEditing: true)
        XCTAssertEqual(model.inputText, "example.org")
        model.escape()
        XCTAssertNil(model.prompt)
        XCTAssertEqual(try saved(model), original)
    }

    func testAddNewFolderIsOneAtomicSaveAndRepeatedEnterDoesNotDuplicate() async throws {
        let model = try await makeModel()
        addThroughTitle(model)
        try choose("__new__", in: model)
        XCTAssertEqual(model.prompt?.field, "folder")
        XCTAssertTrue(model.document.groups.isEmpty)
        model.updateInput("新工作目录")
        model.submitInput()
        model.submitInput()
        XCTAssertTrue(model.busy)
        try await settle { !model.busy }
        let document = try saved(model)
        XCTAssertEqual(document.groups.count, 1)
        XCTAssertEqual(document.bookmarks.count, 1)
        XCTAssertEqual(document.bookmarks[0].groupId, document.groups[0].id)
        XCTAssertNil(model.prompt)
    }

    func testAddValidationAndFailedPersistenceRetainDraftAndDiskContents() async throws {
        let model = try await makeModel(fixture(count: 1))
        model.addBookmark()
        model.updateInput("not a url")
        model.submitInput()
        XCTAssertEqual(model.prompt?.field, "url")
        XCTAssertNotNil(model.prompt?.error)
        model.updateInput("new.example")
        model.switchPromptField(1)
        model.updateInput("保留标题")
        model.switchPromptField(1)
        let file = model.store.directory.appendingPathComponent("bookmarks.json")
        let corrupted = Data("not-json".utf8)
        try corrupted.write(to: file, options: .atomic)
        model.submitInput()
        try await settle { !model.busy }
        XCTAssertEqual(model.prompt?.field, "location")
        XCTAssertNotNil(model.prompt?.error)
        XCTAssertEqual(try Data(contentsOf: file), corrupted)
        _ = model.handleKey(try key(48, "\t", modifiers: .shift), isTextEditing: true)
        XCTAssertEqual(model.inputText, "保留标题")
        XCTAssertEqual(model.document.bookmarks.count, 1)
    }

    func testEditSwitchesDraftFieldsWithoutSelectingOrSavingUntilEnter() async throws {
        let document = fixture(count: 1)
        let model = try await makeModel(document)
        try select(document.bookmarks[0].id, in: model)
        model.runCommand("edit")
        let revision = model.inputRevision
        model.updateInput("新的标题")
        XCTAssertEqual(model.inputRevision, revision)
        XCTAssertFalse(model.handleKey(try key(51, "\u{7f}"), isTextEditing: true))
        _ = model.handleKey(try key(48, "\t"), isTextEditing: true)
        XCTAssertEqual(model.prompt?.field, "url")
        XCTAssertGreaterThan(model.inputRevision, revision)
        model.updateInput("changed.example/path")
        _ = model.handleKey(try key(48, "\t", modifiers: .shift), isTextEditing: true)
        XCTAssertEqual(model.inputText, "新的标题")
        XCTAssertEqual(try saved(model), document)
        model.submitInput()
        try await settle { !model.busy }
        XCTAssertEqual(try saved(model).bookmarks[0].title, "新的标题")
        XCTAssertEqual(model.document.bookmarks[0].url, "https://changed.example/path")
    }

    func testEditValidationReturnsToInvalidFieldWithoutDiscardingOtherDraft() async throws {
        let document = fixture(count: 1)
        let model = try await makeModel(document)
        try select(document.bookmarks[0].id, in: model)
        model.runCommand("edit")
        model.updateInput("")
        _ = model.handleKey(try key(48, "\t"), isTextEditing: true)
        model.updateInput("new.example")
        model.submitInput()
        XCTAssertEqual(model.prompt?.field, "title")
        XCTAssertNotNil(model.prompt?.error)
        model.updateInput("修正标题")
        model.submitInput()
        try await settle { !model.busy }
        XCTAssertEqual(model.document.bookmarks[0].url, "https://new.example")
    }

    func testFolderNamesRejectEmptyOverlongAndDuplicateWithoutDataChange() async throws {
        let first = BookmarkGroup(name: "已有名称")
        let second = BookmarkGroup(name: "另一个", order: 1)
        let document = BookmarkDocument(groups: [first, second])
        let model = try await makeModel(document)
        model.runCommand("mkdir")
        for value in [" ", String(repeating: "字", count: 61), first.name] {
            model.updateInput(value)
            model.submitInput()
            XCTAssertNotNil(model.prompt?.error)
            XCTAssertEqual(try saved(model), document)
        }
        model.escape()
        try select(second.id, in: model)
        model.runCommand("rename")
        model.updateInput(first.name)
        model.submitInput()
        XCTAssertNotNil(model.prompt?.error)
        XCTAssertEqual(try saved(model), document)
        model.updateInput("有效的新名称")
        model.submitInput()
        try await settle { !model.busy }
        XCTAssertEqual(model.document.groups.first { $0.id == second.id }?.name, "有效的新名称")
    }

    func testMoveNewFolderBackCancelAndCommitAreAtomic() async throws {
        let document = fixture(count: 1)
        let model = try await makeModel(document)
        try select(document.bookmarks[0].id, in: model)
        model.runCommand("move")
        try choose("__new__", in: model)
        XCTAssertEqual(model.prompt?.field, "folder")
        model.updateInput("新归属")
        _ = model.handleKey(try key(48, "\t", modifiers: .shift), isTextEditing: true)
        XCTAssertEqual(model.prompt?.field, "to")
        model.switchPromptField(1)
        XCTAssertEqual(model.prompt?.field, "folder")
        XCTAssertEqual(model.inputText, "新归属")
        XCTAssertEqual(try saved(model), document)
        model.escape()
        XCTAssertTrue(model.document.groups.isEmpty)
        model.runCommand("move")
        try choose("__new__", in: model)
        XCTAssertEqual(model.prompt?.field, "folder")
        model.updateInput("最终归属")
        model.submitInput()
        try await settle { !model.busy }
        let result = try saved(model)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.bookmarks[0].groupId, result.groups[0].id)
    }

    func testMoveFailureCannotLeaveOrphanNewFolder() async throws {
        let document = fixture(count: 1)
        let model = try await makeModel(document)
        try select(document.bookmarks[0].id, in: model)
        model.runCommand("move")
        try choose("__new__", in: model)
        XCTAssertEqual(model.prompt?.field, "folder")
        model.updateInput("不能成为空壳")
        try await model.store.apply { try $0.deleteBookmark(id: document.bookmarks[0].id) }
        try await settle { !model.busy }
        model.submitInput()
        try await settle { !model.busy }
        XCTAssertNotNil(model.prompt?.error)
        XCTAssertEqual(model.inputText, "不能成为空壳")
        XCTAssertTrue(try saved(model).groups.isEmpty)
    }

    func testDeleteUsesCapturedIdentityAndDefaultEnterCancels() async throws {
        let document = fixture(count: 2)
        let model = try await makeModel(document)
        try select(document.bookmarks[0].id, in: model)
        model.requestDeleteSelection()
        XCTAssertFalse(model.isTextInputActive)
        model.selectItem(at: 1)
        XCTAssertEqual(model.items[model.selectedIndex].id, document.bookmarks[0].id)
        model.submitInput()
        XCTAssertNil(model.prompt)
        XCTAssertEqual(try saved(model), document)
        model.requestDeleteSelection()
        XCTAssertTrue(model.handleKey(try key(16, "y"), isTextEditing: false))
        try await settle { !model.busy }
        XCTAssertEqual(try saved(model).bookmarks.map(\.id), [document.bookmarks[1].id])
    }

    func testNonemptyFolderCannotBeDeletedAndEmptyFolderCan() async throws {
        let group = BookmarkGroup(name: "工作")
        let bookmark = Bookmark(title: "子项", url: "https://example.com", groupId: group.id)
        let model = try await makeModel(BookmarkDocument(groups: [group], bookmarks: [bookmark]))
        model.requestDeleteSelection()
        XCTAssertNil(model.prompt)
        XCTAssertEqual(model.logs.last?.level, .error)
        try await model.store.apply { try $0.deleteBookmark(id: bookmark.id) }
        try await settle { !model.busy }
        model.requestDeleteSelection()
        XCTAssertEqual(model.prompt?.command, "delete")
        _ = model.handleKey(try key(16, "y"), isTextEditing: false)
        try await settle { !model.busy }
        XCTAssertTrue(try saved(model).groups.isEmpty)
    }

    func testSearchClickHandsKeyboardToResultWithoutClearingQuery() async throws {
        let document = fixture(count: 3)
        let model = try await makeModel(document)
        model.startSearch()
        model.updateInput("example.com")
        XCTAssertEqual(model.items.count, 3)
        model.selectItem(at: 1)
        XCTAssertNil(model.inputKind)
        XCTAssertEqual(model.query, "example.com")
        _ = model.handleKey(try key(14, "e"), isTextEditing: false)
        XCTAssertEqual(model.prompt?.command, "edit")
        XCTAssertEqual(model.inputText, document.bookmarks[1].title)
        model.updateInput("未提交")
        model.selectItem(at: 0)
        XCTAssertEqual(model.inputText, "未提交")
        XCTAssertEqual(model.selectedIndex, 1)
    }

    func testSearchKeyboardSelectionEnablesBookmarkActionsAndResumesQuery() async throws {
        let document = fixture(count: 3)
        let model = try await makeModel(document)
        for (code, index) in [(UInt16(48), 0), (UInt16(125), 1), (UInt16(126), 0)] {
            for (letter, command) in [("e", "edit"), ("m", "move"), ("D", "delete")] {
                model.startSearch()
                model.updateInput("example.com")
                XCTAssertFalse(model.handleKey(try key(14, "e"), isTextEditing: true))
                XCTAssertTrue(model.handleKey(try key(code), isTextEditing: true))
                if code != 48 {
                    XCTAssertEqual(model.inputKind, .search)
                    model.updateInput("example.com/")
                    _ = model.handleKey(try key(code), isTextEditing: true)
                    _ = model.handleKey(try key(48), isTextEditing: true)
                }
                XCTAssertNil(model.inputKind)
                XCTAssertEqual(model.query, code == 48 ? "example.com" : "example.com/")
                XCTAssertEqual(model.selectedIndex, index)
                XCTAssertTrue(model.handleKey(try key(0, letter, modifiers: letter == "D" ? .shift : []), isTextEditing: false))
                XCTAssertEqual(model.prompt?.command, command)
                XCTAssertEqual(model.draft.id, document.bookmarks[index].id)
                model.escape()
                let query = model.query
                XCTAssertTrue(model.handleKey(try key(48, "\t", modifiers: .shift), isTextEditing: false))
                XCTAssertEqual(model.inputKind, .search)
                XCTAssertEqual(model.inputText, query)
            }
        }
    }

    func testEmptySearchResultsKeepInputWhenNavigating() async throws {
        let model = try await makeModel(fixture(count: 1))
        model.startSearch()
        model.updateInput("no-match")
        for code: UInt16 in [48, 125, 126] {
            XCTAssertTrue(model.handleKey(try key(code), isTextEditing: true))
            XCTAssertEqual(model.inputKind, .search)
            XCTAssertEqual(model.query, "no-match")
            XCTAssertNil(model.prompt)
        }
    }

    func testSearchIncludesGroupLabelsAndNoFakeAddResult() async throws {
        let group = BookmarkGroup(name: "工作")
        let bookmark = Bookmark(title: "查找我", url: "https://needle.example", groupId: group.id)
        let root = Bookmark(title: "根目录结果", url: "https://www.needle.example/root", order: 1)
        let model = try await makeModel(BookmarkDocument(groups: [group], bookmarks: [bookmark, root]))
        model.runCommand("find needle")
        XCTAssertEqual(model.items.count, 2)
        XCTAssertEqual(model.items.first { $0.id == bookmark.id }?.groupName, group.name)
        XCTAssertEqual(model.items.first { $0.id == bookmark.id }?.groupID, group.id)
        XCTAssertEqual(model.items.first { $0.id == root.id }?.groupName, "根目录")
        XCTAssertEqual(model.items.first { $0.id == root.id }?.detail, "needle.example")
        XCTAssertTrue(model.items.allSatisfy { $0.kind == .bookmark })
        model.updateInput("完全不存在")
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.scrollIndex, 0)
    }

    func testNormalTextDeletionNavigationAndCommandEditingAreNotConsumed() async throws {
        let model = try await makeModel()
        model.addBookmark()
        for code: UInt16 in [0, 51, 117, 123, 124, 115, 119] {
            XCTAssertFalse(model.handleKey(try key(code, "a"), isTextEditing: true))
        }
        for text in ["a", "c", "v", "x", "z"] {
            XCTAssertFalse(model.handleKey(try key(0, text, modifiers: .command), isTextEditing: true))
        }
        model.escape()
        model.startCommand()
        XCTAssertFalse(model.handleKey(try key(51, "\u{7f}"), isTextEditing: true))
        model.escape()
        for text in ["0", "1", "2", "9"] {
            XCTAssertFalse(model.handleKey(try key(18, text), isTextEditing: false))
        }
    }

    func testMarkedTextRouterPreservesAllIMEKeysAndPromptDraft() async throws {
        let model = try await makeModel()
        model.addBookmark()
        model.updateInput("拼音前的草稿")
        let editor = NSTextView(frame: .zero)
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        for code: UInt16 in [53, 36, 76, 48, 51, 123, 124, 125, 126] {
            XCTAssertFalse(LauncherKeyRouter.handle(try key(code), model: model, firstResponder: editor))
        }
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(model.inputText, "拼音前的草稿")
        XCTAssertEqual(model.prompt?.command, "add")
        editor.unmarkText()
        XCTAssertTrue(LauncherKeyRouter.handle(try key(53), model: model, firstResponder: editor))
        XCTAssertNil(model.prompt)
    }

    func testHideClearsSearchInputAndRestoresUnfilteredList() async throws {
        let document = fixture(count: 3)
        let model = try await makeModel(document)
        model.startSearch()
        model.updateInput("书签 1")
        XCTAssertEqual(model.items.map(\.id), [document.bookmarks[1].id])
        model.didHide()
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.inputText, "")
        XCTAssertNil(model.inputKind)
        XCTAssertEqual(model.items.map(\.id), document.bookmarks.map(\.id))
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.scrollIndex, 0)
        model.startSearch()
        XCTAssertEqual(model.inputText, "")
    }

    func testHideClearsSearchFilterWithoutDiscardingCommandInput() async throws {
        let document = fixture(count: 3)
        let model = try await makeModel(document)
        model.startSearch()
        model.updateInput("书签 1")
        model.startCommand()
        model.updateInput("find other")
        model.didHide()
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.items.map(\.id), document.bookmarks.map(\.id))
        XCTAssertEqual(model.inputKind, .command)
        XCTAssertEqual(model.inputText, "find other")
    }

    func testHidePreservesInputAndRevisionWithoutDiscardingPrompt() async throws {
        let model = try await makeModel()
        model.visible = true
        model.presented = true
        model.addBookmark()
        model.updateInput("尚未保存.example")
        let revision = model.inputRevision
        model.didHide()
        XCTAssertFalse(model.visible)
        XCTAssertFalse(model.presented)
        XCTAssertEqual(model.prompt?.command, "add")
        XCTAssertEqual(model.inputText, "尚未保存.example")
        XCTAssertEqual(model.inputRevision, revision)
    }

    func testOrganizingOnlyReordersBookmarksOnePlaceWithoutMovingFixedEntries() async throws {
        let group = BookmarkGroup(name: "固定文件夹", order: 50)
        var document = fixture(count: 3)
        document.groups = [group]
        let model = try await makeModel(document)
        try select(document.bookmarks[0].id, in: model)
        _ = model.handleKey(try key(31, "o"), isTextEditing: false)
        _ = model.handleKey(try key(125, modifiers: .shift), isTextEditing: false)
        try await settle { !model.busy }
        XCTAssertEqual(model.items.first?.id, group.id)
        XCTAssertEqual(model.items.filter { $0.kind == .bookmark }.count, 3)
        XCTAssertEqual(try saved(model).bookmarks(in: nil).map(\.id), [document.bookmarks[1].id, document.bookmarks[0].id, document.bookmarks[2].id])
        XCTAssertEqual(model.items[model.selectedIndex].id, document.bookmarks[0].id)
        try select(group.id, in: model)
        let before = try saved(model)
        _ = model.handleKey(try key(125, modifiers: .shift), isTextEditing: false)
        XCTAssertEqual(try saved(model), before)
        model.startSearch()
        model.updateInput("example")
        _ = model.handleKey(try key(125, modifiers: .shift), isTextEditing: true)
        XCTAssertEqual(try saved(model), before)
    }

    func testDropIntoFolderReturnRootAndMergePersistRealMembership() async throws {
        var document = fixture(count: 2)
        let group = BookmarkGroup(name: "目的地", order: 20)
        document.groups = [group]
        let model = try await makeModel(document)
        _ = model.handleKey(try key(31, "o"), isTextEditing: false)
        let source = document.bookmarks[0].id
        let target = document.bookmarks[1].id
        model.dropBookmark(sourceID: source, targetID: group.id, before: false, merge: false)
        try await settle { !model.busy }
        XCTAssertEqual(try saved(model).bookmarks.first { $0.id == source }?.groupId, group.id)
        XCTAssertTrue(model.expandedGroupIDs.contains(group.id))
        XCTAssertTrue(model.items.contains { $0.id == source && $0.depth == 1 })
        model.dropBookmark(sourceID: source, targetID: nil, before: false, merge: false)
        try await settle { !model.busy }
        XCTAssertNil(try saved(model).bookmarks.first { $0.id == source }?.groupId)
        model.dropBookmark(sourceID: source, targetID: target, before: false, merge: true)
        try await settle { !model.busy }
        let result = try saved(model)
        XCTAssertEqual(result.groups.count, 2)
        XCTAssertNotNil(result.bookmarks[0].groupId)
        XCTAssertEqual(result.bookmarks[0].groupId, result.bookmarks[1].groupId)
        XCTAssertEqual(result.groups.first { $0.id == group.id }?.name, "目的地")
    }

    func testScrollingAndExternalShrinkClampSelectionWithoutReplacingDraft() async throws {
        let model = try await makeModel(fixture(count: 70))
        _ = model.handleKey(try key(5, "G", modifiers: .shift), isTextEditing: false)
        XCTAssertEqual(model.selectedIndex, 69)
        XCTAssertEqual(model.scrollIndex, 51)
        model.scroll(rows: -10)
        XCTAssertGreaterThanOrEqual(model.selectedIndex, model.scrollIndex)
        XCTAssertLessThan(model.selectedIndex, model.scrollIndex + model.visibleRowCount)
        model.addBookmark()
        model.updateInput("unsaved.example")
        let revision = model.inputRevision
        let replacement = fixture(count: 1)
        try replacement.encoded().write(to: model.store.directory.appendingPathComponent("bookmarks.json"), options: .atomic)
        await model.store.reloadIfChanged()
        try await settle { model.items.count == 1 }
        XCTAssertEqual(model.scrollIndex, 0)
        XCTAssertLessThan(model.selectedIndex, model.items.count)
        XCTAssertEqual(model.inputText, "unsaved.example")
        XCTAssertEqual(model.inputRevision, revision)
    }

    func testBackupUsesRealPathWithSpacesAndRejectsCurrentFile() async throws {
        let document = fixture(count: 2)
        let model = try await makeModel(document)
        let backup = model.store.directory.appendingPathComponent("备份 with spaces.json")
        model.runCommand("backup \(backup.path)")
        try await settle { !model.busy }
        XCTAssertEqual(model.job?.status, .success)
        XCTAssertEqual(try BookmarkDocument.decode(Data(contentsOf: backup)), document)
        XCTAssertEqual(try saved(model), document)
        model.runCommand("backup \(model.store.directory.appendingPathComponent("bookmarks.json").path)")
        try await settle { !model.busy }
        XCTAssertEqual(model.job?.status, .failure)
        XCTAssertEqual(model.prompt?.command, "backup")
        XCTAssertNotNil(model.prompt?.error)
        XCTAssertEqual(try saved(model), document)
    }

    func testRestorePromptWarnsBeforeEnterAndExplicitCommandReplacesWithoutMerging() async throws {
        let model = try await makeModel(fixture(count: 2))
        let replacement = fixture(count: 4)
        let backup = model.store.directory.appendingPathComponent("restore source.json")
        try replacement.encoded().write(to: backup)
        model.runCommand("restore")
        model.updateInput(backup.path)
        XCTAssertEqual(model.prompt?.field, "file")
        XCTAssertTrue(model.isTextInputActive)
        XCTAssertTrue(model.prompt?.hint.contains("替换全部书签与文件夹") == true)
        XCTAssertEqual(model.document.bookmarks.count, 2)
        model.escape()
        XCTAssertNil(model.prompt)
        XCTAssertEqual(model.document.bookmarks.count, 2)
        model.runCommand("restore \(backup.path)")
        model.runCommand("restore \(backup.path)")
        XCTAssertTrue(model.busy)
        try await settle { !model.busy }
        XCTAssertEqual(try saved(model), replacement)
        XCTAssertEqual(model.job?.status, .success)
        XCTAssertNil(model.prompt)
    }

    func testCorruptRestoreRetainsSavedDataAndEditableSourceDraft() async throws {
        let document = fixture(count: 2)
        let model = try await makeModel(document)
        let backup = model.store.directory.appendingPathComponent("corrupt.json")
        try Data("{}".utf8).write(to: backup)
        model.runCommand("restore \(backup.path)")
        try await settle { !model.busy }
        XCTAssertEqual(model.job?.status, .failure)
        XCTAssertEqual(model.prompt?.field, "file")
        XCTAssertEqual(model.inputText, backup.path)
        XCTAssertNotNil(model.prompt?.error)
        XCTAssertEqual(try saved(model), document)
    }

    func testDirectorySwitchSeedsEmptyDirectoryAndReadsExistingFileWithoutChangingOldFile() async throws {
        let document = fixture(count: 2)
        let model = try await makeModel(document)
        let original = model.store.directory
        let target = try directory().appendingPathComponent("space directory")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        model.runCommand("cd \(target.path)")
        try await settle { !model.busy }
        XCTAssertEqual(model.store.directory, target.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(try saved(model), document)
        XCTAssertEqual(try BookmarkDocument.decode(Data(contentsOf: original.appendingPathComponent("bookmarks.json"))), document)
        let existing = try directory()
        let replacement = fixture(count: 1)
        try replacement.encoded().write(to: existing.appendingPathComponent("bookmarks.json"))
        model.runCommand("set data \(existing.path)")
        try await settle { !model.busy }
        XCTAssertEqual(model.document, replacement)
        XCTAssertTrue(model.settingsRows.contains { $0.key == "file" && $0.value == model.store.directory.appendingPathComponent("bookmarks.json").path })
    }

    func testMissingDirectoryFailurePreservesDirectoryDataAndDraft() async throws {
        let document = fixture(count: 2)
        let model = try await makeModel(document)
        let original = model.store.directory
        let missing = original.appendingPathComponent("does not exist")
        model.runCommand("cd \(missing.path)")
        try await settle { !model.busy }
        XCTAssertEqual(model.store.directory, original)
        XCTAssertEqual(try saved(model), document)
        XCTAssertEqual(model.job?.status, .failure)
        XCTAssertEqual(model.inputText, missing.path)
        XCTAssertNotNil(model.prompt?.error)
    }

    func testPathCompletionListsOnlyRealDirectoriesAndJSONFilesAndClickDoesNotSubmit() async throws {
        let model = try await makeModel()
        let base = model.store.directory
        let folder = base.appendingPathComponent("真实目录")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let json = base.appendingPathComponent("实际备份.json")
        try BookmarkDocument().encoded().write(to: json)
        try Data("ignore".utf8).write(to: base.appendingPathComponent("not-json.txt"))
        model.runCommand("restore")
        model.updateInput(base.path + "/")
        let expectedJSON = json.resolvingSymlinksInPath()
        let expectedFolder = folder.resolvingSymlinksInPath()
        try await settle {
            model.prompt?.choices.contains { URL(fileURLWithPath: $0.id).resolvingSymlinksInPath() == expectedJSON } == true
        }
        let choices = try XCTUnwrap(model.prompt?.choices)
        XCTAssertTrue(choices.contains { URL(fileURLWithPath: $0.id).resolvingSymlinksInPath() == expectedFolder })
        XCTAssertFalse(choices.contains { $0.label.hasSuffix(".txt") })
        let jsonChoice = try XCTUnwrap(choices.first { URL(fileURLWithPath: $0.id).resolvingSymlinksInPath() == expectedJSON })
        try choose(jsonChoice.id, in: model)
        XCTAssertEqual(URL(fileURLWithPath: model.inputText).resolvingSymlinksInPath(), expectedJSON)
        XCTAssertEqual(model.prompt?.field, "file")
        XCTAssertFalse(model.busy)
        model.escape()
        model.runCommand("cd")
        model.updateInput(base.path + "/")
        try await settle {
            model.prompt?.choices.contains { URL(fileURLWithPath: $0.id).resolvingSymlinksInPath() == expectedFolder } == true
        }
        for choice in try XCTUnwrap(model.prompt?.choices) {
            XCTAssertTrue(try URL(fileURLWithPath: choice.id).resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        }
    }

    func testExternalConflictRetainsLatestDiskAndEditDraftForExplicitRetry() async throws {
        let original = fixture(count: 1)
        let model = try await makeModel(original)
        try select(original.bookmarks[0].id, in: model)
        model.runCommand("edit")
        model.updateInput("本地未提交标题")
        var external = original
        external.bookmarks.append(Bookmark(title: "外部新增", url: "https://external.example", order: 1))
        try external.encoded().write(to: model.store.directory.appendingPathComponent("bookmarks.json"), options: .atomic)
        model.submitInput()
        try await settle { !model.busy }
        XCTAssertEqual(try saved(model), external)
        XCTAssertEqual(model.document, external)
        XCTAssertEqual(model.inputText, "本地未提交标题")
        XCTAssertEqual(model.prompt?.command, "edit")
        XCTAssertNotNil(model.prompt?.error)
        model.submitInput()
        try await settle { !model.busy }
        XCTAssertEqual(try saved(model).bookmarks.count, 2)
        XCTAssertEqual(model.document.bookmarks.first { $0.id == original.bookmarks[0].id }?.title, "本地未提交标题")
        XCTAssertTrue(model.document.bookmarks.contains { $0.title == "外部新增" })
    }


    func testEscapeHidesWithoutChangingExpandedFolders() async throws {
        let a = BookmarkGroup(name: "A", order: 1)
        let b = BookmarkGroup(name: "B", order: 2)
        let child = Bookmark(title: "子书签", url: "https://child.example", groupId: a.id)
        let model = try await makeModel(BookmarkDocument(groups: [a, b], bookmarks: [child]))
        model.toggleAllExpanded()
        try select(child.id, in: model)
        var hidden = false
        model.dismissWindow = { hidden = true }
        model.escape()
        XCTAssertTrue(hidden)
        XCTAssertEqual(model.expandedGroupIDs, Set([a.id, b.id]))
        XCTAssertEqual(model.items[model.selectedIndex].id, child.id)
    }

    func testExpandedFoldersPersistAndPruneDeletedGroups() async throws {
        let group = BookmarkGroup(name: "工作")
        let suite = "frog.tests.expanded.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try directory()
        try BookmarkDocument(groups: [group]).encoded().write(to: directory.appendingPathComponent("bookmarks.json"))
        let store = BookmarkStore(directoryOverride: directory, persistDirectory: false)
        await store.load()
        let model = LauncherModel(store: store, isolated: false, defaults: defaults)
        XCTAssertTrue(model.expandedGroupIDs.isEmpty)
        model.toggleExpanded(group.id)
        XCTAssertEqual(defaults.stringArray(forKey: LauncherModel.expandedDefaultsKey), [group.id])
        let reopened = LauncherModel(store: store, isolated: false, defaults: defaults)
        XCTAssertEqual(reopened.expandedGroupIDs, Set([group.id]))
        reopened.expandedGroupIDs.insert("missing")
        reopened.rebuildItems()
        XCTAssertEqual(reopened.expandedGroupIDs, Set([group.id]))
    }

    func testIsolatedLoginCommandsReportControllerErrorsWithoutClaimingSystemActions() async throws {
        let model = try await makeModel()
        let enabled = model.login.enabled
        for value in ["on", "off", "approve"] {
            let start = model.logs.count
            model.runCommand("set login \(value)")
            let error = try XCTUnwrap(model.login.error)
            XCTAssertEqual(model.logs.last?.level, .error)
            XCTAssertEqual(model.logs.last?.text, error)
            XCTAssertEqual(model.login.enabled, enabled)
            XCTAssertFalse(model.login.changing)
            XCTAssertFalse(model.logs.dropFirst(start).contains {
                $0.text.hasPrefix("已打开系统") || $0.text.hasPrefix("已请求系统")
            })
            XCTAssertTrue(model.settingsRows.contains { $0.kind == .note && $0.value == error && $0.level == .error })
        }
    }

    func testSettingsStatusTracksRealLogCountIncludingClear() async throws {
        let model = try await makeModel(fixture(count: 3))
        XCTAssertEqual(model.settingsRows.first { $0.key == "bookmarks" }?.value, "3")
        XCTAssertEqual(model.settingsRows.first { $0.key == "groups" }?.value, "0")
        XCTAssertEqual(model.settingsRows.first { $0.key == "schema" }?.value, "frog-bookmarks v1")
        model.runCommand("unknown-command")
        XCTAssertEqual(model.settingsRows.first { $0.key == "log" }?.value, "\(model.logs.count) 条")
        model.runCommand("clear")
        XCTAssertTrue(model.logs.isEmpty)
        XCTAssertEqual(model.settingsRows.first { $0.key == "log" }?.value, "0 条")
    }

    func testSettingsHaveNoSingleLetterActionsAndSeparateDataFromOperations() async throws {
        let model = try await makeModel(fixture(count: 3))
        model.selectItem(at: 1)
        model.openSettings()
        XCTAssertEqual(model.modeLabel, "BUFFER:SETTINGS")
        let initial = model.settingsRows
        for character in ["l", "h", "r", "c", "a", "n", "e", "m", "D", "C", "o", "1"] {
            _ = model.handleKey(try key(0, character), isTextEditing: false)
        }
        for modifiers: NSEvent.ModifierFlags in [.command, .control, .option] {
            XCTAssertFalse(model.handleKey(try key(0, "a", modifiers: modifiers), isTextEditing: false))
        }
        XCTAssertEqual(model.selectedIndex, 1)
        XCTAssertNil(model.inputKind)
        XCTAssertFalse(model.isOrganizing)
        XCTAssertEqual(model.buffer, .settings)
        XCTAssertNil(model.prompt)
        XCTAssertEqual(model.settingsRows, initial)
        let fileIndex = try XCTUnwrap(initial.firstIndex { $0.key == "file" })
        XCTAssertEqual(initial[fileIndex].value, model.store.directory.appendingPathComponent("bookmarks.json").path)
        XCTAssertTrue(model.handleKey(try key(41, ":", modifiers: .shift), isTextEditing: false))
        XCTAssertEqual(model.inputKind, .command)
        XCTAssertEqual(model.modeLabel, "COMMAND")
        model.escape()
        XCTAssertEqual(model.buffer, .settings)
        XCTAssertEqual(model.modeLabel, "BUFFER:SETTINGS")
        model.escape()
        XCTAssertNil(model.buffer)
        model.openBuffer(.help)
        XCTAssertEqual(model.modeLabel, "BUFFER:HELP")
        model.runCommand("mkdir")
        XCTAssertEqual(model.buffer, .help)
        XCTAssertNil(model.prompt)
        XCTAssertEqual(model.logs.last?.level, .error)
        XCTAssertEqual(model.modeLabel, "BUFFER:HELP")
        model.startSearch()
        XCTAssertEqual(model.modeLabel, "SEARCH")
    }

    func testExpandedStateIsNotPrunedBeforeStoreLoads() async throws {
        let group = BookmarkGroup(name: "工作")
        let suite = "frog.tests.launch-order.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([group.id], forKey: LauncherModel.expandedDefaultsKey)
        let directory = try directory()
        try BookmarkDocument(groups: [group]).encoded().write(to: directory.appendingPathComponent("bookmarks.json"))
        let store = BookmarkStore(directoryOverride: directory, persistDirectory: false)
        let model = LauncherModel(store: store, isolated: false, defaults: defaults)
        XCTAssertEqual(model.expandedGroupIDs, Set([group.id]))
        await store.load()
        try await settle { model.items.contains { $0.kind == .folder } }
        XCTAssertEqual(model.expandedGroupIDs, Set([group.id]))
        XCTAssertEqual(defaults.stringArray(forKey: LauncherModel.expandedDefaultsKey), [group.id])
    }

    func testTabInBufferDoesNotToggleFolders() async throws {
        let group = BookmarkGroup(name: "工作")
        let model = try await makeModel(BookmarkDocument(groups: [group]))
        model.openBuffer(.help)
        XCTAssertTrue(model.handleKey(try key(48, "\t"), isTextEditing: false))
        XCTAssertEqual(model.buffer, .help)
        XCTAssertTrue(model.expandedGroupIDs.isEmpty)
    }

    func testGroupCommandClearsBufferAndSearchThenExpands() async throws {
        let group = BookmarkGroup(name: "工作")
        let model = try await makeModel(BookmarkDocument(groups: [group]))
        model.startSearch()
        model.updateInput("工作")
        model.openBuffer(.help)
        model.runCommand("group 工作")
        XCTAssertNil(model.buffer)
        XCTAssertEqual(model.query, "")
        XCTAssertTrue(model.expandedGroupIDs.contains(group.id))
        XCTAssertEqual(model.items[model.selectedIndex].id, group.id)
    }

    func testGroupNavigationDropsOldCalculatorOriginForNextAuxiliaryPage() async throws {
        let group = BookmarkGroup(name: "工作")
        let model = try await makeModel(BookmarkDocument(groups: [group]))
        for command in ["group root", "group 工作"] {
            model.openCalc()
            model.updateInput("12*7")
            model.startCommand()
            model.updateInput("help")
            model.submitInput()
            model.startCommand()
            model.updateInput(command)
            model.submitInput()
            XCTAssertNil(model.buffer)
            model.openSettings()
            model.escape()
            XCTAssertNil(model.buffer)
            XCTAssertNil(model.inputKind)
            XCTAssertEqual(model.calcExpression, "12*7")
        }
    }

    func testAuxiliaryCommandRejectionKeepsDataAndExposesFeedbackUntilNextAction() async throws {
        let document = fixture(count: 1)
        let model = try await makeModel(document)
        for buffer in [TerminalBuffer.help, .settings, .log, .job] {
            model.openBuffer(buffer)
            model.startCommand()
            model.updateInput("delete")
            model.submitInput()
            XCTAssertEqual(model.buffer, buffer)
            XCTAssertNil(model.prompt)
            XCTAssertNotNil(model.bufferFeedback)
            XCTAssertEqual(try saved(model), document)
            model.startCommand()
            XCTAssertNil(model.bufferFeedback)
            model.escape()
            model.runCommand("add")
            XCTAssertNotNil(model.bufferFeedback)
            model.escape()
            XCTAssertNil(model.bufferFeedback)
        }
    }

    func testFunctionKeyF1NoLongerOpensBuffer() async throws {
        let model = try await makeModel(fixture(count: 3))
        XCTAssertFalse(model.handleKey(try key(122), isTextEditing: false))
        XCTAssertNil(model.buffer)
    }

    func testBareCommaOpensSettingsAndCommandCommaOpensSettings() async throws {
        let model = try await makeModel(fixture(count: 3))
        model.selectItem(at: 1)
        XCTAssertTrue(model.handleKey(try key(43, ","), isTextEditing: false))
        XCTAssertEqual(model.buffer, .settings)
        model.escape()
        XCTAssertNil(model.buffer)
        XCTAssertEqual(model.selectedIndex, 1)
        XCTAssertTrue(model.handleKey(try key(43, ",", modifiers: .command), isTextEditing: false))
        XCTAssertEqual(model.buffer, .settings)
    }

    func testOpenRejectsArgumentsAndBuffersKeepSearchAndHelpShortcuts() async throws {
        let model = try await makeModel(fixture(count: 3))
        model.runCommand("open 3")
        XCTAssertEqual(model.logs.last?.level, .error)
        XCTAssertEqual(model.selectedIndex, 0)
        model.openBuffer(.log)
        XCTAssertTrue(model.handleKey(try key(44, "/"), isTextEditing: false))
        XCTAssertNil(model.buffer)
        XCTAssertEqual(model.inputKind, .search)
        model.openBuffer(.log)
        XCTAssertTrue(model.handleKey(try key(44, "?", modifiers: .shift), isTextEditing: false))
        XCTAssertEqual(model.buffer, .help)
    }

    func testCommandHistoryCompletionUsesActualCommandCatalog() async throws {
        let model = try await makeModel()
        model.startCommand()
        model.updateInput("hel")
        _ = model.handleKey(try key(48, "\t"), isTextEditing: true)
        XCTAssertEqual(model.inputText, "help")
        model.submitInput()
        XCTAssertEqual(model.buffer, .help)
        model.startCommand()
        model.updateInput("未提交命令")
        _ = model.handleKey(try key(126, modifiers: .option), isTextEditing: true)
        XCTAssertEqual(model.inputText, "help")
        _ = model.handleKey(try key(125, modifiers: .option), isTextEditing: true)
        XCTAssertEqual(model.inputText, "未提交命令")
        model.escape()
        model.runCommand("set")
        XCTAssertEqual(model.buffer, .settings)
        XCTAssertNil(model.inputKind)
    }

    func testCalculatorOpensEvaluatesFiltersAndPreservesExpression() async throws {
        let model = try await makeModel()
        model.runCommand("calc")
        XCTAssertEqual(model.buffer, .calc)
        XCTAssertEqual(model.inputKind, .calc)
        XCTAssertTrue(model.isTextInputActive)
        model.updateInput("（1+2）*3abc")
        XCTAssertEqual(model.inputText, "(1+2)*3")
        XCTAssertEqual(model.calcExpression, "(1+2)*3")
        XCTAssertTrue(model.handleKey(try key(36), isTextEditing: true))
        XCTAssertEqual(model.calcHistory.count, 1)
        XCTAssertEqual(model.calcHistory.first?.value, "9")
        XCTAssertEqual(model.inputText, "(1+2)*3")
        XCTAssertNil(model.calcError)
        model.escape()
        XCTAssertNil(model.buffer)
        XCTAssertNil(model.inputKind)
        model.runCommand("calc")
        XCTAssertEqual(model.inputText, "(1+2)*3")
        XCTAssertEqual(model.calcHistory.count, 1)
    }

    func testCalculatorRejectsInvalidExpressionsWithoutWritingHistory() async throws {
        let model = try await makeModel()
        model.runCommand("calc")
        model.updateInput("1/0")
        XCTAssertTrue(model.handleKey(try key(36), isTextEditing: true))
        XCTAssertEqual(model.calcHistory.count, 0)
        XCTAssertEqual(model.calcError, "不能除以 0")
        XCTAssertNil(model.calcFeedback)
        model.updateInput("1+2")
        XCTAssertNil(model.calcError)
        XCTAssertNil(model.calcFeedback)
        XCTAssertFalse(model.handleKey(try key(24, "="), isTextEditing: true))
        XCTAssertTrue(model.calcHistory.isEmpty)
        XCTAssertTrue(model.handleKey(try key(36), isTextEditing: true))
        XCTAssertEqual(model.calcHistory.count, 1)
        XCTAssertEqual(model.calcHistory.first?.value, "3")
    }

    func testCalculatorHistoryBrowsingPreservesDraftUntilExplicitLoad() async throws {
        let model = try await makeModel()
        model.runCommand("calc")
        model.updateInput("12*(8-3)")
        model.submitCalc()
        model.updateInput("7*6")
        model.submitCalc()
        model.updateInput("123+")
        XCTAssertFalse(model.handleKey(try key(126), isTextEditing: true))
        _ = model.handleKey(try key(48), isTextEditing: true)
        _ = model.handleKey(try key(125), isTextEditing: false)
        XCTAssertEqual(model.calcHistoryIndex, 1)
        XCTAssertEqual(model.calcExpression, "123+")
        XCTAssertTrue(model.handleKey(try key(8, "c", modifiers: .command), isTextEditing: false))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "60")
        model.escape()
        XCTAssertEqual(model.inputText, "123+")
        XCTAssertEqual(model.inputKind, .calc)
        _ = model.handleKey(try key(48), isTextEditing: true)
        _ = model.handleKey(try key(36), isTextEditing: false)
        XCTAssertEqual(model.inputText, "12*(8-3)")
        XCTAssertEqual(model.calcHistory.count, 2)
        XCTAssertEqual(model.inputKind, .calc)
    }

    func testCalculatorCopyHandlesLiveAndMissingResults() async throws {
        let model = try await makeModel()
        model.runCommand("calc")
        NSPasteboard.general.clearContents()
        XCTAssertTrue(model.handleKey(try key(8, "c", modifiers: .command), isTextEditing: true))
        XCTAssertEqual(model.calcFeedback, "✗ 没有可复制的结果")
        model.updateInput("12*(8-3)")
        XCTAssertTrue(model.handleKey(try key(8, "c", modifiers: .command), isTextEditing: true))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "60")
        XCTAssertEqual(model.calcFeedback, "✓ 已复制 60")
        XCTAssertEqual(model.inputText, "12*(8-3)")
    }

    func testCalculatorRejectsHiddenBookmarkCommandsWithoutLosingDraft() async throws {
        let document = fixture(count: 1)
        let model = try await makeModel(document)
        model.runCommand("calc")
        model.updateInput("5*5")
        for command in ["add", "edit", "rename", "delete", "move", "open", "mkdir 新目录"] {
            model.runCommand(command)
            XCTAssertNil(model.prompt)
            XCTAssertEqual(model.buffer, .calc)
            XCTAssertEqual(model.inputKind, .calc)
            XCTAssertEqual(model.inputText, "5*5")
            XCTAssertEqual(try saved(model), document)
        }
    }

    func testAuxiliaryBuffersReturnToCalculatorHistoryFocus() async throws {
        let model = try await makeModel()
        model.openCalc()
        model.updateInput("6*7")
        model.submitCalc()
        model.updateInput("8+")
        model.selectCalcEntry(at: 0)
        model.startCommand()
        model.updateInput("help")
        model.submitInput()
        model.openSettings()
        model.escape()
        XCTAssertEqual(model.buffer, .calc)
        XCTAssertTrue(model.calcHistoryFocused)
        XCTAssertNil(model.inputKind)
        XCTAssertEqual(model.calcExpression, "8+")
        model.escape()
        XCTAssertEqual(model.inputText, "8+")
    }

    func testCalculatorCommandErrorsAndClearUseVisibleFeedback() async throws {
        let model = try await makeModel()
        model.runCommand("calc")
        model.runCommand("calc foo")
        XCTAssertEqual(model.calcFeedback, "✗ 用法：:calc 打开，:calc clear 清空")
        model.updateInput("1+1")
        model.submitCalc()
        model.runCommand("calc clear")
        XCTAssertEqual(model.calcFeedback, "✓ 已清空")
        XCTAssertEqual(model.buffer, .calc)
        XCTAssertEqual(model.inputKind, .calc)
        XCTAssertEqual(model.inputText, "")
    }

    func testCalculatorClearAndCommandRoundTripRestoreExpression() async throws {
        let model = try await makeModel()
        model.runCommand("calc")
        model.updateInput("3*4")
        model.submitCalc()
        XCTAssertEqual(model.calcHistory.count, 1)
        model.runCommand("calc clear")
        XCTAssertTrue(model.calcHistory.isEmpty)
        XCTAssertEqual(model.calcExpression, "")
        XCTAssertEqual(model.inputText, "")
        XCTAssertEqual(model.buffer, .calc)
        XCTAssertEqual(model.inputKind, .calc)

        model.updateInput("5*5")
        XCTAssertTrue(model.handleKey(try key(41, ":"), isTextEditing: true))
        XCTAssertEqual(model.inputKind, .command)
        model.updateInput("log")
        model.escape()
        XCTAssertEqual(model.buffer, .calc)
        XCTAssertEqual(model.inputKind, .calc)
        XCTAssertEqual(model.inputText, "5*5")
        model.startCommand()
        model.submitInput()
        XCTAssertEqual(model.inputKind, .calc)
        XCTAssertEqual(model.inputText, "5*5")

        XCTAssertTrue(model.handleKey(try key(41, ":"), isTextEditing: true))
        model.updateInput("help")
        model.submitInput()
        XCTAssertEqual(model.buffer, .help)
        XCTAssertNil(model.inputKind)
    }

    func testCalculatorCommandDeleteClearsAllAndShiftDDeletesSingleHistoryEntry() async throws {
        let model = try await makeModel()
        model.runCommand("calc")
        model.updateInput("2+2")
        model.submitCalc()
        model.updateInput("3*5")
        model.submitCalc()
        XCTAssertEqual(model.calcHistory.map(\.value), ["15", "4"])

        // Shift+D in history focus deletes only selected entry
        model.selectCalcEntry(at: 0)
        XCTAssertTrue(model.handleKey(try key(2, "D", modifiers: .shift), isTextEditing: false))
        XCTAssertEqual(model.calcHistory.map(\.value), ["4"])
        XCTAssertTrue(model.calcHistoryFocused)
        XCTAssertEqual(model.calcHistoryIndex, 0)
        XCTAssertEqual(model.calcFeedback, "✓ 已删除记录")

        // Deleting last history entry returns focus to input
        XCTAssertTrue(model.handleKey(try key(2, "D", modifiers: .shift), isTextEditing: false))
        XCTAssertTrue(model.calcHistory.isEmpty)
        XCTAssertFalse(model.calcHistoryFocused)
        XCTAssertEqual(model.inputKind, .calc)

        // Command+Delete clears expression and history from input focus
        model.updateInput("9*9")
        model.submitCalc()
        XCTAssertEqual(model.calcHistory.count, 1)
        XCTAssertTrue(model.handleKey(try key(51, "\u{7f}", modifiers: .command), isTextEditing: true))
        XCTAssertEqual(model.calcExpression, "")
        XCTAssertEqual(model.inputText, "")
        XCTAssertTrue(model.calcHistory.isEmpty)
        XCTAssertEqual(model.calcFeedback, "✓ 已清空")

        // Command+Delete also works from history focus
        model.updateInput("6+7")
        model.submitCalc()
        model.selectCalcEntry(at: 0)
        XCTAssertTrue(model.handleKey(try key(51, "\u{7f}", modifiers: .command), isTextEditing: false))
        XCTAssertEqual(model.calcExpression, "")
        XCTAssertTrue(model.calcHistory.isEmpty)
        XCTAssertFalse(model.calcHistoryFocused)
        XCTAssertEqual(model.inputKind, .calc)
    }

    func testImportEdgeCommandMergesDeduplicatesAndPreservesDataOnFailure() async throws {
        let model = try await makeModel()
        let edge = try directory().appendingPathComponent("Edge 数据")
        let profile = edge.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let json: [String: Any] = ["version": 1, "roots": [
            "bookmark_bar": ["type": "folder", "name": "收藏夹栏", "children": [
                ["type": "url", "name": "A", "url": "https://a.test/", "date_added": "0"],
                ["type": "folder", "name": "开发", "children": [
                    ["type": "url", "name": "B", "url": "https://b.test/"]
                ]]
            ]],
            "other": ["type": "folder", "name": "其他收藏夹", "children": []]
        ]]
        try JSONSerialization.data(withJSONObject: json)
            .write(to: profile.appendingPathComponent("Bookmarks"))

        model.runCommand("import edge \"\(edge.path)\"")
        XCTAssertTrue(model.busy)
        try await settle { !model.busy }

        let firstJob = try XCTUnwrap(model.job)
        XCTAssertEqual(firstJob.status, .success)
        let first = try saved(model)
        XCTAssertEqual(first.bookmarks.map(\.url), ["https://a.test/", "https://b.test/"])
        XCTAssertEqual(Set(first.groups.map(\.name)), ["收藏夹栏", "收藏夹栏 / 开发", "其他收藏夹"])
        XCTAssertEqual(first.bookmarks(in: nil).count, 0)

        model.runCommand("import edge \"\(edge.path)\"")
        try await settle { !model.busy }
        let secondJob = try XCTUnwrap(model.job)
        XCTAssertEqual(secondJob.status, .success)
        XCTAssertEqual(try saved(model), first)

        let beforeFailure = try Data(contentsOf: model.store.directory.appendingPathComponent("bookmarks.json"))
        let corruptProfile = edge.appendingPathComponent("Profile 1")
        try FileManager.default.createDirectory(at: corruptProfile, withIntermediateDirectories: true)
        let corrupt = Data("{broken".utf8)
        let corruptFile = corruptProfile.appendingPathComponent("Bookmarks")
        try corrupt.write(to: corruptFile)
        model.runCommand("import edge \"\(edge.path)\"")
        try await settle { !model.busy }
        XCTAssertEqual(model.job?.status, .failure)
        XCTAssertEqual(model.document, first)
        XCTAssertEqual(try Data(contentsOf: model.store.directory.appendingPathComponent("bookmarks.json")), beforeFailure)
        XCTAssertEqual(try Data(contentsOf: corruptFile), corrupt)
    }

    func testClearOnlyRemovesLogsAndQuitInvokesApplicationCallback() async throws {
        let document = fixture(count: 1)
        let model = try await makeModel(document)
        model.runCommand("does-not-exist")
        XCTAssertEqual(model.logs.last?.level, .error)
        model.runCommand("clear")
        XCTAssertTrue(model.logs.isEmpty)
        XCTAssertEqual(try saved(model), document)
        var didQuit = false
        model.terminateApplication = { didQuit = true }
        model.runCommand("q")
        XCTAssertTrue(didQuit)
    }
}
