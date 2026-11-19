import AppKit
import XCTest
import FrogCore
@testable import Frog

@MainActor
final class BookmarkKeyboardTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
        super.tearDown()
    }

    private func model(_ document: BookmarkDocument = BookmarkDocument(),
                       clipboard: String? = nil) async throws -> LauncherModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Frog-Bookmark-Keys-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        try document.encoded().write(to: directory.appendingPathComponent("bookmarks.json"))
        let store = BookmarkStore(directoryOverride: directory, persistDirectory: false)
        await store.load()
        let launcher = LauncherModel(store: store, isolated: true)
        launcher.readClipboardString = { clipboard }
        return launcher
    }

    @discardableResult
    private func press(_ code: UInt16, in model: LauncherModel, modifiers: NSEvent.ModifierFlags = [], text: String = "") throws -> Bool {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        return model.handleKey(event, isTextEditing: model.isTextInputActive)
    }

    private func settle(_ model: LauncherModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.busy && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(model.busy)
    }

    func testAddEnterAdvancesThroughFieldsAndSavesOnLocation() async throws {
        let group = BookmarkGroup(name: "开发")
        let rootBookmark = Bookmark(title: "首页", url: "https://root.example")
        let model = try await model(BookmarkDocument(groups: [group], bookmarks: [rootBookmark]))
        model.selectItem(at: 1) // select root bookmark so default location is __root__
        model.addBookmark()
        XCTAssertEqual(model.prompt?.field, "url")
        XCTAssertEqual(model.draft.location, "__root__")
        model.updateInput("www.example.org/docs")
        // Enter on URL advances to title with clean host title
        try press(36, in: model)
        XCTAssertEqual(model.prompt?.field, "title")
        XCTAssertEqual(model.inputText, "example.org")
        XCTAssertEqual(model.document.bookmarks.count, 1)
        // Enter on title advances to location
        model.updateInput("示例文档")
        try press(36, in: model)
        XCTAssertEqual(model.prompt?.field, "location")
        XCTAssertEqual(model.inputText, "")
        XCTAssertTrue(model.isTextInputActive)
        // Arrow down selects folder and Enter saves + auto-expands
        try press(125, in: model)
        XCTAssertEqual(model.draft.location, group.id)
        try press(36, in: model)
        try await settle(model)
        XCTAssertNil(model.prompt)
        let added = try XCTUnwrap(model.document.bookmarks.first { $0.title == "示例文档" })
        XCTAssertEqual(added.url, "https://www.example.org/docs")
        XCTAssertEqual(added.groupId, group.id)
        XCTAssertTrue(model.expandedGroupIDs.contains(group.id))
        XCTAssertEqual(model.items[model.selectedIndex].id, added.id)
    }

    func testCommandEnterFromURLSavesDefaultsImmediately() async throws {
        let model = try await model()
        model.addBookmark()
        model.updateInput("www.example.org:8443/path")
        try press(36, in: model, modifiers: .command)
        try await settle(model)
        XCTAssertNil(model.prompt)
        XCTAssertEqual(model.document.bookmarks.first?.title, "example.org:8443")
        XCTAssertEqual(model.document.bookmarks.first?.url, "https://www.example.org:8443/path")
    }

    func testClipboardPrefillsValidHTTPURLAndIgnoresPlainText() async throws {
        let prefilled = try await model(clipboard: "  https://www.swift.org/documentation  ")
        prefilled.addBookmark()
        XCTAssertEqual(prefilled.prompt?.field, "url")
        XCTAssertEqual(prefilled.inputText, "https://www.swift.org/documentation")
        XCTAssertEqual(prefilled.draft.title, "swift.org")
        XCTAssertTrue(prefilled.draft.prefilledFromClipboard)
        XCTAssertFalse(prefilled.draft.titleEdited)

        let plain = try await model(clipboard: "not a url just text")
        plain.addBookmark()
        XCTAssertEqual(plain.inputText, "")
        XCTAssertFalse(plain.draft.prefilledFromClipboard)

        let bareDomain = try await model(clipboard: "example.com")
        bareDomain.addBookmark()
        XCTAssertEqual(bareDomain.inputText, "")
        XCTAssertFalse(bareDomain.draft.prefilledFromClipboard)
    }

    func testAddInheritsSelectedFolderContextAndDetectsDuplicateURL() async throws {
        let group = BookmarkGroup(name: "工作")
        let existing = Bookmark(title: "旧书签", url: "https://example.org", groupId: group.id)
        let model = try await model(BookmarkDocument(groups: [group], bookmarks: [existing]),
                                    clipboard: "https://example.org")
        model.selectItem(at: 0) // folder row
        model.addBookmark()
        XCTAssertEqual(model.draft.location, group.id)
        XCTAssertEqual(model.duplicateBookmarkForDraft?.bookmark.id, existing.id)
        XCTAssertEqual(model.duplicateBookmarkForDraft?.locationName, "工作")
        // Verify summary rows reflect inherited location and prefilled URL
        XCTAssertEqual(model.bookmarkSummaryRows.map(\.label), ["网址", "标题", "位置"])
        XCTAssertEqual(model.bookmarkSummaryRows[2].value, "工作")
    }

    func testAutoTitleTracksURLChangesUntilUserEditsTitle() async throws {
        let model = try await model()
        model.addBookmark()
        model.updateInput("www.first.example")
        XCTAssertEqual(model.draft.title, "first.example")
        model.updateInput("www.second.example")
        XCTAssertEqual(model.draft.title, "second.example")
        try press(48, in: model)
        XCTAssertEqual(model.prompt?.field, "title")
        XCTAssertEqual(model.inputText, "second.example")
        model.updateInput("手写标题")
        try press(48, in: model, modifiers: .shift)
        model.updateInput("not a url")
        try press(48, in: model)
        XCTAssertEqual(model.inputText, "手写标题")
        try press(36, in: model, modifiers: .command)
        XCTAssertEqual(model.prompt?.field, "url")
        XCTAssertNotNil(model.prompt?.error)
        XCTAssertEqual(model.draft.title, "手写标题")
        XCTAssertTrue(model.document.bookmarks.isEmpty)
        model.updateInput("third.example")
        try press(48, in: model)
        XCTAssertEqual(model.inputText, "手写标题")
        XCTAssertFalse(try press(125, in: model, modifiers: .shift))
        XCTAssertFalse(try press(48, in: model, modifiers: .option))
    }

    func testVisitingAutoTitleDoesNotFreezeItBeforeSaving() async throws {
        let model = try await model()
        let view = LauncherView(model: model)
        model.addBookmark()
        model.updateInput("https://first.example")
        try press(36, in: model)
        model.updateInput(model.inputText)
        try press(48, in: model, modifiers: .shift)
        model.updateInput("https://second.example")
        view.perform(.promptField("title"))
        XCTAssertEqual(model.inputText, "second.example")
        view.perform(.promptField("url"))
        model.updateInput("https://third.example")
        try press(36, in: model, modifiers: .command)
        try await settle(model)
        let saved = try XCTUnwrap(model.document.bookmarks.first)
        XCTAssertEqual(saved.title, "third.example")
        XCTAssertEqual(saved.url, "https://third.example")
    }

    func testClickableEscapePreservesDraftBeforeCancelling() async throws {
        let work = BookmarkGroup(name: "工作", order: 0)
        let bookmark = Bookmark(title: "原始标题", url: "https://original.example")
        for command in ["add", "edit", "move"] {
            let model = try await model(BookmarkDocument(groups: [work], bookmarks: [bookmark]))
            let view = LauncherView(model: model)
            model.selectedIndex = try XCTUnwrap(model.items.firstIndex { $0.id == bookmark.id })
            switch command {
            case "add":
                model.addBookmark()
                model.updateInput("https://draft.example")
                try press(36, in: model)
                model.updateInput("未保存标题")
                try press(36, in: model)
            case "edit":
                model.beginEdit()
                model.updateInput("未保存标题")
                view.perform(.promptField("location"))
            default: model.beginMove()
            }
            let title = model.draft.title
            model.updateInput("工")
            view.perform(.ui(.togglePromptChoices))
            let returnHint = try XCTUnwrap(view.currentShortcutHints().first { $0.key == "Esc" })
            view.perform(try XCTUnwrap(returnHint.action))
            XCTAssertEqual(model.prompt?.choicesFocused, false)
            XCTAssertEqual(model.inputText, "工")
            XCTAssertEqual(model.draft.title, title)
            let clearHint = try XCTUnwrap(view.currentShortcutHints().first { $0.key == "Esc" })
            view.perform(try XCTUnwrap(clearHint.action))
            XCTAssertEqual(model.prompt?.command, command)
            XCTAssertEqual(model.inputText, "")
            XCTAssertEqual(model.draft.title, title)
            XCTAssertEqual(model.draft.location, work.id)
            XCTAssertEqual(model.document.bookmarks, [bookmark])
            view.perform(.ui(.escape))
            XCTAssertNil(model.prompt)
        }
    }

    func testLocationFilterArrowsAndEscapeClearFilterBeforeCancelling() async throws {
        let dev = BookmarkGroup(name: "开发", order: 0)
        let work = BookmarkGroup(name: "工作", order: 1)
        let model = try await model(BookmarkDocument(groups: [dev, work]))
        model.addBookmark()
        model.updateInput("example.org")
        try press(36, in: model)
        try press(36, in: model)
        XCTAssertEqual(model.prompt?.field, "location")
        model.updateInput("工")
        XCTAssertEqual(model.prompt?.choices.map(\.label), ["工作"])
        XCTAssertEqual(model.draft.location, work.id)
        // First Escape clears filter query instead of closing prompt
        try press(53, in: model)
        XCTAssertNotNil(model.prompt)
        XCTAssertEqual(model.inputText, "")
        XCTAssertEqual(model.prompt?.choices.count, 4) // 根目录, 开发, 工作, 新建文件夹…
        // Tab cycles cleanly to next field without trapping in secondary choice focus
        try press(48, in: model)
        XCTAssertEqual(model.prompt?.field, "url")
        XCTAssertEqual(model.draft.location, work.id)
    }

    func testNewFolderAdvancesDirectlyFromLocationAndSavesAtomically() async throws {
        let model = try await model()
        model.addBookmark()
        model.updateInput("example.org")
        try press(36, in: model)
        model.updateInput("保留标题")
        try press(36, in: model)
        XCTAssertEqual(model.prompt?.field, "location")
        try press(125, in: model) // selects 新建文件夹…
        XCTAssertEqual(model.draft.location, "__new__")
        XCTAssertEqual(model.prompt?.total, 4)
        // Enter on 新建文件夹… advances directly to folder naming
        try press(36, in: model)
        XCTAssertEqual(model.prompt?.field, "folder")
        XCTAssertTrue(model.document.groups.isEmpty)
        // Empty folder name fails validation and keeps draft
        try press(36, in: model)
        XCTAssertEqual(model.prompt?.field, "folder")
        XCTAssertNotNil(model.prompt?.error)
        XCTAssertEqual(model.draft.title, "保留标题")
        model.updateInput("新文件夹")
        try press(36, in: model)
        try await settle(model)
        XCTAssertEqual(model.document.groups.count, 1)
        let groupID = try XCTUnwrap(model.document.groups.first?.id)
        XCTAssertEqual(model.document.bookmarks.first?.groupId, groupID)
        XCTAssertTrue(model.expandedGroupIDs.contains(groupID))
    }

    func testPathCandidateNavigationAndEscapePreserveDraft() async throws {
        let model = try await model()
        model.beginFilePrompt("cd", path: "original/")
        model.completionTask?.cancel()
        model.prompt?.choices = [TerminalChoice(id: "one", label: "/one/"), TerminalChoice(id: "two", label: "/two/")]
        try press(48, in: model)
        try press(125, in: model)
        XCTAssertEqual(model.inputText, "original/")
        XCTAssertEqual(model.draft.path, "original/")
        try press(53, in: model)
        XCTAssertNotNil(model.prompt)
        XCTAssertEqual(model.prompt?.choicesFocused, false)
        try press(48, in: model)
        try press(36, in: model)
        XCTAssertEqual(model.inputText, "/two/")
        XCTAssertEqual(model.draft.path, "/two/")
        XCTAssertNotNil(model.prompt)
        XCTAssertFalse(model.busy)
    }

    func testDeleteOnlyBareYConfirms() async throws {
        let bookmark = Bookmark(title: "保留", url: "https://example.org")
        let model = try await model(BookmarkDocument(bookmarks: [bookmark]))
        for (code, text) in [(UInt16(36), ""), (UInt16(53), ""), (UInt16(45), "n")] {
            model.requestDeleteSelection()
            try press(code, in: model, text: text)
            XCTAssertNil(model.prompt)
            XCTAssertEqual(model.document.bookmarks.count, 1)
        }
        model.requestDeleteSelection()
        XCTAssertFalse(try press(0, in: model, text: "a"))
        XCTAssertNotNil(model.prompt)
        XCTAssertFalse(try press(16, in: model, modifiers: .command, text: "y"))
        XCTAssertNotNil(model.prompt)
        try press(16, in: model, text: "y")
        try await settle(model)
        XCTAssertTrue(model.document.bookmarks.isEmpty)
    }

    func testMoveCandidateSelectionMovesOnEnterAndExpandsTargetFolder() async throws {
        let first = BookmarkGroup(name: "一", order: 0)
        let second = BookmarkGroup(name: "二", order: 1)
        let bookmark = Bookmark(title: "书签", url: "https://example.org")
        let model = try await model(BookmarkDocument(groups: [first, second], bookmarks: [bookmark]))
        model.selectItem(at: try XCTUnwrap(model.items.firstIndex { $0.id == bookmark.id }))
        model.beginMove()
        XCTAssertEqual(model.draft.location, first.id)
        try press(125, in: model)
        XCTAssertEqual(model.draft.location, second.id)
        XCTAssertNil(model.document.bookmarks.first?.groupId)
        try press(36, in: model)
        try await settle(model)
        XCTAssertEqual(model.document.bookmarks.first?.groupId, second.id)
        XCTAssertTrue(model.expandedGroupIDs.contains(second.id))
    }

    func testEditIncludesLocationAndNewFolderFieldsAndExpandsOnSave() async throws {
        let bookmark = Bookmark(title: "原题", url: "https://example.org")
        let model = try await model(BookmarkDocument(bookmarks: [bookmark]))
        model.beginEdit()
        XCTAssertEqual(model.prompt?.field, "title")
        model.updateInput("新题")
        try press(48, in: model)
        XCTAssertEqual(model.prompt?.field, "url")
        try press(48, in: model)
        XCTAssertEqual(model.prompt?.field, "location")
        try press(125, in: model) // selects 新建文件夹…
        try press(36, in: model)  // enters folder field directly
        XCTAssertEqual(model.prompt?.field, "folder")
        model.updateInput("归档")
        try press(36, in: model)
        try await settle(model)
        XCTAssertEqual(model.document.bookmarks.count, 1)
        XCTAssertEqual(model.document.bookmarks.first?.title, "新题")
        let groupID = try XCTUnwrap(model.document.groups.first?.id)
        XCTAssertEqual(model.document.bookmarks.first?.groupId, groupID)
        XCTAssertEqual(model.document.groups.first?.name, "归档")
        XCTAssertTrue(model.expandedGroupIDs.contains(groupID))
    }

    func testSearchActionDistinguishesURLFromWebSearch() async throws {
        let model = try await model()
        model.startSearch()
        XCTAssertEqual(model.searchAction, .finish)
        XCTAssertEqual(model.searchAction.title, "结束搜索")
        model.updateInput("swift.org")
        XCTAssertEqual(model.searchAction, .openURL)
        XCTAssertEqual(model.searchAction.title, "打开网址")
        model.updateInput("swift concurrency")
        XCTAssertEqual(model.searchAction, .webSearch)
        XCTAssertEqual(model.searchAction.title, "Google 搜索")
    }

    func testViewPromptFieldClickAndSettingActionMapping() async throws {
        let model = try await model()
        let view = LauncherView(model: model)
        model.addBookmark()
        model.updateInput("example.org")
        view.perform(.promptField("title"))
        XCTAssertEqual(model.prompt?.field, "title")
        XCTAssertEqual(model.inputText, "example.org")
        view.perform(.ui(.escape))
        XCTAssertNil(model.prompt)
        if case .command("log") = LauncherView.settingAction(for: ":log") {} else { XCTFail("Expected :log command action") }
        if case .draft("set corner") = LauncherView.settingAction(for: ":set corner left-up/left-down") {} else { XCTFail("Expected set corner draft") }
    }

    func testBottomShortcutHintsExposeAllActiveActionsAcrossPages() async throws {
        let group = BookmarkGroup(name: "开发")
        let bookmark = Bookmark(title: "示例", url: "https://example.org")
        let model = try await model(BookmarkDocument(groups: [group], bookmarks: [bookmark]))
        let view = LauncherView(model: model)

        // 1. Main list: folder selected
        model.selectItem(at: 0)
        let folderKeys = view.currentShortcutHints().map(\.key)
        XCTAssertTrue(folderKeys.contains("Enter"))
        XCTAssertTrue(folderKeys.contains("a"))
        XCTAssertTrue(folderKeys.contains("n"))
        XCTAssertTrue(folderKeys.contains("e"))
        XCTAssertTrue(folderKeys.contains("⇧D"))
        XCTAssertTrue(folderKeys.contains("o"))
        XCTAssertTrue(folderKeys.contains("z"))
        XCTAssertTrue(folderKeys.contains(","))
        XCTAssertTrue(folderKeys.contains("?"))

        // 2. Main list: bookmark selected
        model.selectItem(at: 1)
        let bookmarkKeys = view.currentShortcutHints().map(\.key)
        for required in ["↑↓", "Enter", "a", "n", "e", "m", "⇧D", "⌘C", "o", "z", "/", ":", ",", "?", "Esc"] {
            XCTAssertTrue(bookmarkKeys.contains(required), "主列表选中书签缺少快捷键 \(required)")
        }

        // 3. Organize mode: bookmark selected
        model.toggleOrganizing()
        let organizeKeys = view.currentShortcutHints().map(\.key)
        for required in ["↑↓", "⇧↑↓", "m", "e", "⌘C", "⇧D", "Esc"] {
            XCTAssertTrue(organizeKeys.contains(required), "整理模式缺少快捷键 \(required)")
        }
        model.escape()

        // 4. Add bookmark prompt: url step & location filter step
        model.addBookmark()
        let addURLHints = view.currentShortcutHints()
        XCTAssertTrue(addURLHints.contains { $0.key == "Enter" && $0.label == "下一步" })
        XCTAssertTrue(addURLHints.contains { $0.key == "⌘Enter" && $0.label == "保存" })
        model.updateInput("example.org")
        try press(36, in: model)
        try press(36, in: model)
        model.updateInput("开")
        let addLocationHints = view.currentShortcutHints()
        XCTAssertTrue(addLocationHints.contains { $0.key == "↑↓" })
        XCTAssertTrue(addLocationHints.contains { $0.key == "Esc" && $0.label == "清空筛选" })
        model.escape()
        model.escape()

        // 5. Custom commands list & create mode
        await model.customLoadTask?.value
        model.customCommands = [CustomCommand(name: "demo", title: "演示", type: .url, target: "https://example.org")]
        model.openCustomCommands()
        let customListKeys = view.currentShortcutHints().map(\.key)
        for required in ["↑↓", "Enter", "a", "e", "⌘C", "⌘D", "⇧D", "/", ":", ",", "?", "Esc"] {
            XCTAssertTrue(customListKeys.contains(required), "自定义命令列表缺少快捷键 \(required)")
        }
        model.beginCustomEdit()
        let customCreateHints = view.currentShortcutHints()
        XCTAssertTrue(customCreateHints.contains { $0.key == "Enter" && $0.label == "下一步" })
        XCTAssertTrue(customCreateHints.contains { $0.key == "⌘Enter" && $0.label == "保存" })
        model.selectCustomField(try XCTUnwrap(model.customFields.firstIndex(of: .type)))
        XCTAssertTrue(view.currentShortcutHints().contains { $0.key == "↑↓/←→" })
        model.escapeCustomCommands()
        model.escapeCustomCommands()

        // 6. Calculator expression & history focus
        model.openCalc()
        model.updateInput("2+3")
        model.submitCalc()
        let calcInputKeys = view.currentShortcutHints().map(\.key)
        for required in ["Enter", "Tab", "⌘C", "⌘⌫", ":", "⌘,", "Esc"] {
            XCTAssertTrue(calcInputKeys.contains(required), "计算器输入态缺少快捷键 \(required)")
        }
        model.selectCalcEntry(at: 0)
        let calcHistoryKeys = view.currentShortcutHints().map(\.key)
        for required in ["↑↓", "Enter", "⌘C", "⇧D", "⌘⌫", ":", "Esc"] {
            XCTAssertTrue(calcHistoryKeys.contains(required), "计算器历史态缺少快捷键 \(required)")
        }
    }
}
