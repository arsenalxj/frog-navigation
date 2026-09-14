import AppKit
import XCTest
import FrogCore
import FrogIcons
@testable import Frog

@MainActor
final class LauncherModelTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
        super.tearDown()
    }

    private func makeModel(_ document: BookmarkDocument = BookmarkDocument()) async throws -> LauncherModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Frog-UI-Tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        try document.encoded().write(to: directory.appendingPathComponent("bookmarks.json"))
        let store = BookmarkStore(directoryOverride: directory, persistDirectory: false)
        await store.load()
        let model = LauncherModel(store: store, icons: IconStore(cacheDirectory: directory.appendingPathComponent("cache"), networkingEnabled: false), isolated: true)
        model.reduceMotion = true
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

    func testRootPaginationUsesFullCapacityWithoutVirtualItems() async throws {
        let document = fixture(count: 50)
        let model = try await makeModel(document)
        XCTAssertEqual(model.rootPages[0].count, model.metrics.capacity)
        XCTAssertEqual(model.rootPages[0].last?.id, document.bookmarks[model.metrics.capacity - 1].id)
        XCTAssertFalse(model.rootPages.joined().contains(.add))
        XCTAssertTrue(model.rootPages.joined().allSatisfy(\.movable))
        XCTAssertEqual(model.rootPages.flatMap { $0 }.filter { $0.movable }.count, 50)
        let exported = try BookmarkDocument.decode(model.document.encoded())
        XCTAssertEqual(exported, document)
        let empty = try await makeModel()
        XCTAssertEqual(empty.rootPages, [[]])
        XCTAssertTrue(empty.activeItems.isEmpty)
        empty.addBookmark()
        XCTAssertTrue(empty.showEditor)
        XCTAssertEqual(empty.draft.location, "__root__")
    }

    func testFolderKeepsAddEntryAndAddingUsesCurrentLocation() async throws {
        let group = BookmarkGroup(name: "工作")
        let model = try await makeModel(BookmarkDocument(groups: [group]))
        model.folderID = group.id
        XCTAssertEqual(model.folderPages, [[.add]])
        model.addBookmark()
        XCTAssertEqual(model.draft.location, group.id)
        model.showEditor = false; model.draft = BookmarkDraft(); model.folderID = nil
        model.query = "没有匹配的搜索"
        model.addBookmark()
        XCTAssertTrue(model.showEditor)
        XCTAssertEqual(model.draft.location, "__root__")
    }

    func testSavingFillsLastRootSlotBeforeRevealingNextPage() async throws {
        let model = try await makeModel()
        let count = model.metrics.capacity - 1
        try await model.store.apply { $0 = self.fixture(count: count) }
        model.draft = BookmarkDraft(url: "example.org/last", title: "本页最后一个")
        model.saveDraft()
        try await settle { !model.savingDraft }
        XCTAssertEqual(model.rootPage, 0)
        XCTAssertEqual(model.rootPages.count, 1)
        XCTAssertEqual(model.activeItems.last?.id, model.selection)
        model.draft = BookmarkDraft(url: "example.org/next", title: "下一页第一个")
        model.saveDraft()
        try await settle { !model.savingDraft }
        XCTAssertEqual(model.rootPage, 1)
        XCTAssertEqual(model.rootPages.count, 2)
        XCTAssertEqual(model.activeItems.first?.id, model.selection)
    }

    func testEscapeHandlesOneLayerAndPreservesDraft() async throws {
        let group = BookmarkGroup(name: "工作")
        let model = try await makeModel(BookmarkDocument(groups: [group]))
        model.folderID = group.id; model.query = "example"; model.editing = true
        model.showSettings = true; model.showEditor = true
        model.draft.title = "未保存草稿"
        var hidden = false
        model.dismissWindow = { hidden = true }
        model.escape()
        XCTAssertFalse(model.showEditor); XCTAssertTrue(model.showSettings)
        XCTAssertEqual(model.draft.title, "未保存草稿")
        model.escape(); XCTAssertFalse(model.showSettings); XCTAssertTrue(model.editing)
        model.escape(); XCTAssertFalse(model.editing); XCTAssertEqual(model.query, "example")
        model.escape(); XCTAssertEqual(model.query, ""); XCTAssertEqual(model.folderID, group.id)
        model.escape(); XCTAssertNil(model.folderID); XCTAssertFalse(hidden)
        model.escape(); XCTAssertTrue(hidden)
    }

    func testFailedSaveKeepsDraftAndPreviousFile() async throws {
        let model = try await makeModel(fixture(count: 2))
        let file = model.store.directory.appendingPathComponent("bookmarks.json")
        let previous = try Data(contentsOf: file)
        model.draft = BookmarkDraft(url: "example.com", title: " ")
        model.showEditor = true
        model.saveDraft()
        try await settle { !model.savingDraft }
        XCTAssertTrue(model.showEditor)
        XCTAssertEqual(model.draft.url, "example.com")
        XCTAssertNotNil(model.draft.error)
        XCTAssertEqual(try Data(contentsOf: file), previous)
    }

    func testSaveRejectsRepeatedSubmissionAndRevealsActualPage() async throws {
        let model = try await makeModel(fixture(count: 40))
        model.draft = BookmarkDraft(url: "example.org", title: "新增书签")
        model.showEditor = true
        model.saveDraft(); model.saveDraft()
        try await settle { !model.savingDraft }
        XCTAssertEqual(model.store.document.bookmarks.count, 41)
        XCTAssertFalse(model.showEditor)
        XCTAssertEqual(model.rootPage, 1)
        XCTAssertTrue(model.activeItems.contains { $0.id == model.selection })
        XCTAssertEqual(model.store.document.bookmarks.last?.url, "https://example.org")
    }

    func testNewFolderSaveNavigatesIntoFolder() async throws {
        let model = try await makeModel()
        model.draft = BookmarkDraft(url: "example.com", title: "工作台", location: "__new__", newFolderName: "工作")
        model.saveDraft()
        try await settle { !model.savingDraft }
        XCTAssertEqual(model.store.document.groups.count, 1)
        XCTAssertEqual(model.folderID, model.store.document.groups[0].id)
        XCTAssertEqual(model.activeItems.filter { $0.movable }.count, 1)
    }

    func testDragReorderIsPreviewOnlyUntilDropAndEscapeCancels() async throws {
        let document = fixture(count: 2)
        let model = try await makeModel(document)
        let file = model.store.directory.appendingPathComponent("bookmarks.json")
        let previous = try Data(contentsOf: file)
        model.frames["root::\(document.bookmarks[1].id)"] = CGRect(x: 200, y: 100, width: 120, height: 150)
        model.drag(.bookmark(document.bookmarks[0]), point: CGPoint(x: 310, y: 200))
        XCTAssertEqual(model.document.rootItems.map(\.id), [document.bookmarks[1].id, document.bookmarks[0].id])
        XCTAssertEqual(try Data(contentsOf: file), previous)
        model.escape()
        XCTAssertNil(model.dragItem)
        XCTAssertEqual(model.document, document)
        XCTAssertEqual(try Data(contentsOf: file), previous)
    }

    func testDroppedReorderPersistsExactlyOnce() async throws {
        let document = fixture(count: 2)
        let model = try await makeModel(document)
        let point = CGPoint(x: 310, y: 200)
        model.frames["root::\(document.bookmarks[1].id)"] = CGRect(x: 200, y: 100, width: 120, height: 150)
        model.drag(.bookmark(document.bookmarks[0]), point: point)
        model.finishDrag(point: point)
        try await settle { model.store.document.rootItems.first?.id == document.bookmarks[1].id }
        let saved = try BookmarkDocument.decode(Data(contentsOf: model.store.directory.appendingPathComponent("bookmarks.json")))
        XCTAssertEqual(saved.rootItems.map(\.id), [document.bookmarks[1].id, document.bookmarks[0].id])
        model.finishDrag(point: point)
        XCTAssertEqual(model.store.document, saved)
    }

    func testCrossPageDropOnBlankAppendsAfterThatPage() async throws {
        let document = fixture(count: 40)
        let model = try await makeModel(document)
        model.drag(.bookmark(document.bookmarks[0]), point: CGPoint(x: 300, y: 300))
        model.setPage(1, animated: false)
        model.frames = [:]
        model.finishDrag(point: CGPoint(x: 900, y: 500))
        try await settle { model.store.document.rootItems.last?.id == document.bookmarks[0].id }
        XCTAssertEqual(model.store.document.rootItems.last?.id, document.bookmarks[0].id)
    }

    func testHideResetsNavigationButKeepsDraftAndRootPage() async throws {
        let model = try await makeModel(fixture(count: 40))
        model.rootPage = 1; model.query = "example"; model.editing = true
        model.draft = BookmarkDraft(url: "draft.example", title: "草稿")
        model.showEditor = true
        model.didHide()
        XCTAssertEqual(model.rootPage, 1)
        XCTAssertEqual(model.query, "")
        XCTAssertFalse(model.editing)
        XCTAssertEqual(model.draft.title, "草稿")
        XCTAssertTrue(model.showEditor)
    }

    func testHoverOnlyCreatesFolderAfterDwellAndSuccessfulDrop() async throws {
        let document = fixture(count: 2)
        let model = try await makeModel(document)
        let point = CGPoint(x: 260, y: 130)
        model.frames["root::\(document.bookmarks[1].id)"] = CGRect(x: 200, y: 100, width: 120, height: 150)
        model.drag(.bookmark(document.bookmarks[0]), point: point)
        XCTAssertNil(model.mergeTarget)
        model.cancelDrag()
        XCTAssertEqual(model.store.document.groups.count, 0)
        model.drag(.bookmark(document.bookmarks[0]), point: point)
        try await settle { model.mergeTarget == document.bookmarks[1].id }
        XCTAssertEqual(model.store.document.groups.count, 0)
        model.finishDrag(point: point)
        try await settle { model.store.document.groups.count == 1 }
        XCTAssertEqual(model.store.document.bookmarks(in: model.store.document.groups[0].id).count, 2)
        try await settle { model.renamingID != nil }
        XCTAssertEqual(model.renamingID, model.folderID)
    }

    func testDragOutOfFolderAndCancelRestoresMembershipAndFolder() async throws {
        let group = BookmarkGroup(name: "工作")
        let bookmark = Bookmark(title: "工作台", url: "https://example.com", groupId: group.id)
        let document = BookmarkDocument(groups: [group], bookmarks: [bookmark])
        let model = try await makeModel(document)
        model.folderID = group.id
        model.folderFrame = CGRect(x: 400, y: 200, width: 620, height: 500)
        model.drag(.bookmark(bookmark), point: CGPoint(x: 200, y: 300))
        XCTAssertNil(model.folderID)
        XCTAssertNil(model.document.bookmarks[0].groupId)
        XCTAssertEqual(model.store.document.bookmarks[0].groupId, group.id)
        model.cancelDrag()
        XCTAssertEqual(model.folderID, group.id)
        XCTAssertEqual(model.document, document)
    }

    func testExternalReloadKeepsEditorDraft() async throws {
        let model = try await makeModel(fixture(count: 2))
        model.draft = BookmarkDraft(url: "example.org", title: "未提交标题")
        model.showEditor = true
        let replacement = fixture(count: 5)
        try replacement.encoded().write(to: model.store.directory.appendingPathComponent("bookmarks.json"), options: .atomic)
        await model.store.reloadIfChanged()
        XCTAssertEqual(model.store.document.bookmarks.count, 5)
        XCTAssertEqual(model.draft.title, "未提交标题")
        XCTAssertEqual(model.draft.url, "example.org")
        XCTAssertTrue(model.showEditor)
    }

    func testPageWindowClampsImmediatelyWhenSearchOrDataShrinks() {
        let window = PageWindow(requestedPage: 2, pageCount: 1)
        XCTAssertEqual(window.current, 0)
        XCTAssertEqual(Array(window.indices), [0])
        XCTAssertTrue(PageWindow(requestedPage: 100, pageCount: 0).indices.isEmpty)
        XCTAssertEqual(Array(PageWindow(requestedPage: -4, pageCount: 3).indices), [0, 1])
    }

    func testGridKeepsIconsAndDotsAboveLargeDockAndInsideSideDock() {
        let metrics = GridMetrics(size: CGSize(width: 1440, height: 900), dockInsets: DockInsets(left: 130, right: 0, bottom: 190))
        XCTAssertLessThanOrEqual(metrics.top + metrics.height, 900 - 190 - 49)
        XCTAssertLessThan(metrics.dotsY, 900 - 190)
        XCTAssertGreaterThan(metrics.centerX - metrics.width / 2, 130)
        XCTAssertLessThan(metrics.centerX + metrics.width / 2, 1440)
    }

    func testNativePointerStartsFromHitFrameAndSuppressesDropClick() async throws {
        let document = fixture(count: 2)
        let model = try await makeModel(document)
        model.visible = true
        model.frames["root::\(document.bookmarks[0].id)"] = CGRect(x: 100, y: 100, width: 120, height: 150)
        model.frames["root::\(document.bookmarks[1].id)"] = CGRect(x: 250, y: 100, width: 120, height: 150)
        model.pointerDown(at: CGPoint(x: 160, y: 135))
        XCTAssertFalse(model.pointerDragged(to: CGPoint(x: 163, y: 136)))
        XCTAssertNil(model.dragItem)
        XCTAssertTrue(model.pointerDragged(to: CGPoint(x: 360, y: 200)))
        XCTAssertEqual(model.dragItem?.id, document.bookmarks[0].id)
        XCTAssertTrue(model.pointerUp(at: CGPoint(x: 360, y: 200)))
        model.activate(.add)
        XCTAssertFalse(model.showEditor, "drop 同一事件不能再触发按钮点击")
        try await settle { model.store.document.rootItems.first?.id == document.bookmarks[1].id }
    }

    func testNativePointerOrdinaryClickAndEscapeCancellation() async throws {
        let document = fixture(count: 2)
        let model = try await makeModel(document)
        model.visible = true
        model.frames["root::\(document.bookmarks[0].id)"] = CGRect(x: 100, y: 100, width: 120, height: 150)
        model.pointerDown(at: CGPoint(x: 160, y: 135))
        XCTAssertFalse(model.pointerUp(at: CGPoint(x: 160, y: 135)))
        model.activate(.add)
        XCTAssertTrue(model.showEditor)
        model.showEditor = false
        model.pointerDown(at: CGPoint(x: 160, y: 135))
        XCTAssertTrue(model.pointerDragged(to: CGPoint(x: 300, y: 200)))
        model.escape()
        XCTAssertNil(model.dragItem)
        XCTAssertFalse(model.pointerDragged(to: CGPoint(x: 500, y: 200)))
        model.pointerUp(at: CGPoint(x: 500, y: 200))
        XCTAssertEqual(model.store.document, document)
    }

    func testNativeLongPressEntersEditingWithoutOpeningFolder() async throws {
        let folder = BookmarkGroup(name: "工作")
        let model = try await makeModel(BookmarkDocument(groups: [folder]))
        model.visible = true
        model.frames["root::\(folder.id)"] = CGRect(x: 100, y: 100, width: 120, height: 150)
        model.pointerDown(at: CGPoint(x: 160, y: 135))
        try await settle { model.editing }
        XCTAssertTrue(model.pointerUp(at: CGPoint(x: 160, y: 135)))
        model.activate(.folder(folder))
        XCTAssertNil(model.folderID)
    }

    private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }

    func testMarkedTextKeepsNativeEscapeReturnAndArrowHandling() async throws {
        let group = BookmarkGroup(name: "工作")
        let model = try await makeModel(BookmarkDocument(groups: [group]))
        let editor = NSTextView(frame: .zero)
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        model.showEditor = true
        XCTAssertFalse(LauncherKeyRouter.handle(try key(53), model: model, firstResponder: editor))
        XCTAssertTrue(model.showEditor)
        model.showEditor = false
        for code: UInt16 in [36, 76, 123, 124, 125, 126] {
            model.folderID = nil; model.selection = nil
            XCTAssertFalse(LauncherKeyRouter.handle(try key(code), model: model, firstResponder: editor))
            XCTAssertNil(model.folderID)
            XCTAssertNil(model.selection)
        }
        XCTAssertTrue(editor.hasMarkedText())
        editor.unmarkText()
        model.showEditor = true
        XCTAssertTrue(LauncherKeyRouter.handle(try key(53), model: model, firstResponder: editor))
        XCTAssertFalse(model.showEditor)
        model.folderID = nil; model.selection = nil
        XCTAssertTrue(LauncherKeyRouter.handle(try key(36), model: model, firstResponder: editor))
        XCTAssertEqual(model.folderID, group.id)
    }

    func testKeyboardPageChangeInvalidatesMergeBeforeDrop() async throws {
        let document = fixture(count: 40)
        let model = try await makeModel(document)
        let target = document.bookmarks[1]
        let point = CGPoint(x: 260, y: 130)
        model.frames["root::\(target.id)"] = CGRect(x: 200, y: 100, width: 120, height: 150)
        model.drag(.bookmark(document.bookmarks[0]), point: point)
        try await settle { model.mergeTarget == target.id }
        XCTAssertTrue(LauncherKeyRouter.handle(try key(121), model: model, firstResponder: nil))
        XCTAssertEqual(model.rootPage, 1)
        XCTAssertNil(model.mergeTarget)
        // 保留上一页 frame，模拟 SwiftUI 还未提交新一页布局的 mouseUp。
        model.finishDrag(point: point)
        try await settle { model.store.document != document }
        XCTAssertTrue(model.store.document.groups.isEmpty)
        XCTAssertEqual(model.store.document.rootItems.last?.id, document.bookmarks[0].id)
    }

    func testDropOutsideDwelledIconDoesNotMerge() async throws {
        let document = fixture(count: 2)
        let model = try await makeModel(document)
        let target = document.bookmarks[1]
        model.frames["root::\(target.id)"] = CGRect(x: 200, y: 100, width: 120, height: 150)
        model.drag(.bookmark(document.bookmarks[0]), point: CGPoint(x: 260, y: 130))
        try await settle { model.mergeTarget == target.id }
        model.finishDrag(point: CGPoint(x: 900, y: 500))
        try await settle { model.store.document != document }
        XCTAssertTrue(model.store.document.groups.isEmpty)
        XCTAssertEqual(model.store.document.rootItems.last?.id, document.bookmarks[0].id)
    }

    func testSearchFromOpenFolderAddsAtRootAndKeepsExistingDraft() async throws {
        let group = BookmarkGroup(name: "工作")
        let model = try await makeModel(BookmarkDocument(groups: [group]))
        model.openFolder(group)
        model.query = "全局搜索"; model.queryChanged()
        model.addBookmark()
        XCTAssertEqual(model.draft.location, "__root__")
        model.draft = BookmarkDraft(url: "example.com", title: "未提交", location: group.id)
        model.showEditor = false
        model.addBookmark()
        XCTAssertEqual(model.draft.title, "未提交")
        XCTAssertEqual(model.draft.location, group.id)
    }

    func testEscapeClosesOverlayBeforeInlineRenameAndPreservesText() async throws {
        let group = BookmarkGroup(name: "工作")
        let model = try await makeModel(BookmarkDocument(groups: [group]))
        model.rename(group); model.renameText = "尚未保存的名称"
        let initialFocus = try XCTUnwrap(model.renameFocusToken)
        model.addBookmark()
        XCTAssertNil(model.renameFocusToken)
        XCTAssertNotNil(model.editorFocusToken)
        model.escape()
        XCTAssertFalse(model.showEditor)
        XCTAssertNil(model.editorFocusToken)
        XCTAssertNotEqual(try XCTUnwrap(model.renameFocusToken), initialFocus)
        XCTAssertEqual(model.renamingID, group.id)
        XCTAssertEqual(model.renameText, "尚未保存的名称")
        model.showSettings = true
        XCTAssertNil(model.renameFocusToken)
        model.escape()
        XCTAssertFalse(model.showSettings)
        XCTAssertNotNil(model.renameFocusToken)
        XCTAssertEqual(model.renamingID, group.id)
        XCTAssertEqual(model.renameText, "尚未保存的名称")
        model.escape()
        XCTAssertNil(model.renamingID)
        XCTAssertNil(model.renameFocusToken)
        XCTAssertEqual(model.folderID, group.id)
    }

    func testEscapeAndFocusFollowStandaloneRenameDeleteEditorSettingsOrder() async throws {
        let group = BookmarkGroup(name: "工作")
        let bookmark = Bookmark(title: "书签", url: "https://example.com")
        let model = try await makeModel(BookmarkDocument(groups: [group], bookmarks: [bookmark]))
        model.renamingID = group.id; model.renameText = "保留名称"
        model.deleteTarget = .bookmark(bookmark); model.showEditor = true; model.showSettings = true
        XCTAssertNotNil(model.renameFocusToken)
        XCTAssertNil(model.editorFocusToken)
        model.escape()
        XCTAssertNil(model.renamingID)
        XCTAssertNotNil(model.deleteTarget)
        XCTAssertTrue(model.showEditor); XCTAssertTrue(model.showSettings)
        XCTAssertNil(model.editorFocusToken)
        model.escape()
        XCTAssertNil(model.deleteTarget)
        XCTAssertNotNil(model.editorFocusToken)
        model.escape()
        XCTAssertFalse(model.showEditor); XCTAssertTrue(model.showSettings)
        XCTAssertNil(model.editorFocusToken)
        model.escape()
        XCTAssertFalse(model.showSettings)
        XCTAssertEqual(model.renameText, "保留名称")
    }

    func testDropWithoutCompletedDwellDoesNotCreateFolder() async throws {
        let document = fixture(count: 2)
        let model = try await makeModel(document)
        let point = CGPoint(x: 260, y: 130)
        model.frames["root::\(document.bookmarks[1].id)"] = CGRect(x: 200, y: 100, width: 120, height: 150)
        model.drag(.bookmark(document.bookmarks[0]), point: point)
        XCTAssertNil(model.mergeTarget)
        model.finishDrag(point: point)
        XCTAssertNil(model.dragItem)
        XCTAssertEqual(model.store.document, document)
    }

    func testEdgePageChangeStillAllowsCrossPageDrop() async throws {
        let document = fixture(count: 40)
        let model = try await makeModel(document)
        model.drag(.bookmark(document.bookmarks[0]), point: CGPoint(x: model.metrics.size.width - 10, y: 500))
        try await settle { model.rootPage == 1 }
        XCTAssertNotNil(model.dragItem)
        model.finishDrag(point: CGPoint(x: 900, y: 500))
        try await settle { model.store.document != document }
        XCTAssertTrue(model.store.document.groups.isEmpty)
        XCTAssertEqual(model.store.document.rootItems.last?.id, document.bookmarks[0].id)
    }
}
