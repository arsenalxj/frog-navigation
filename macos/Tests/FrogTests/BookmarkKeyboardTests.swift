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

    private func model(_ document: BookmarkDocument = BookmarkDocument()) async throws -> LauncherModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Frog-Bookmark-Keys-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        try document.encoded().write(to: directory.appendingPathComponent("bookmarks.json"))
        let store = BookmarkStore(directoryOverride: directory, persistDirectory: false)
        await store.load()
        return LauncherModel(store: store, isolated: true)
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

    func testEnterFromURLSavesDefaultsWithoutAdvancing() async throws {
        let model = try await model()
        model.addBookmark()
        model.updateInput("example.org")
        try press(36, in: model)
        try await settle(model)
        XCTAssertNil(model.prompt)
        XCTAssertEqual(model.document.bookmarks.first?.title, "example.org")
        XCTAssertEqual(model.document.bookmarks.first?.url, "https://example.org")
    }

    func testFieldRoundTripRetainsUserTitleAndValidationDraft() async throws {
        let model = try await model()
        model.addBookmark()
        model.updateInput("first.example")
        try press(48, in: model)
        XCTAssertEqual(model.prompt?.field, "title")
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
        model.updateInput("second.example")
        try press(48, in: model)
        XCTAssertEqual(model.inputText, "手写标题")
        XCTAssertFalse(try press(125, in: model, modifiers: .shift))
        XCTAssertFalse(try press(48, in: model, modifiers: .option))
    }

    func testLocationCandidateEnterAdoptsWithoutSavingAndCommandEnterIgnoresHighlight() async throws {
        let group = BookmarkGroup(name: "工作")
        let model = try await model(BookmarkDocument(groups: [group]))
        model.addBookmark()
        model.updateInput("example.org")
        try press(48, in: model)
        try press(48, in: model)
        XCTAssertEqual(model.prompt?.field, "location")
        try press(48, in: model)
        XCTAssertEqual(model.prompt?.choicesFocused, true)
        XCTAssertFalse(model.isTextInputActive)
        try press(125, in: model)
        XCTAssertEqual(model.draft.location, "__root__")
        try press(36, in: model)
        XCTAssertEqual(model.draft.location, group.id)
        XCTAssertEqual(model.prompt?.choicesFocused, false)
        XCTAssertTrue(model.document.bookmarks.isEmpty)
        try press(48, in: model)
        try press(125, in: model)
        try press(36, in: model, modifiers: .command)
        try await settle(model)
        XCTAssertEqual(model.document.bookmarks.first?.groupId, group.id)
        XCTAssertEqual(model.document.groups.count, 1)
    }

    func testNewFolderValidationFocusesNameAndSavesAtomically() async throws {
        let model = try await model()
        model.addBookmark()
        model.updateInput("example.org")
        try press(48, in: model)
        model.updateInput("保留标题")
        try press(48, in: model)
        try press(48, in: model)
        try press(125, in: model)
        try press(36, in: model)
        try press(36, in: model)
        XCTAssertEqual(model.prompt?.field, "folder")
        XCTAssertNotNil(model.prompt?.error)
        XCTAssertEqual(model.draft.title, "保留标题")
        XCTAssertTrue(model.document.groups.isEmpty)
        model.updateInput("新文件夹")
        try press(36, in: model)
        try await settle(model)
        XCTAssertEqual(model.document.groups.count, 1)
        XCTAssertEqual(model.document.bookmarks.first?.groupId, model.document.groups.first?.id)
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
    func testMoveCandidateSelectionDoesNotMoveUntilSaved() async throws {
        let first = BookmarkGroup(name: "一", order: 0)
        let second = BookmarkGroup(name: "二", order: 1)
        let bookmark = Bookmark(title: "书签", url: "https://example.org")
        let model = try await model(BookmarkDocument(groups: [first, second], bookmarks: [bookmark]))
        model.selectItem(at: try XCTUnwrap(model.items.firstIndex { $0.id == bookmark.id }))
        model.beginMove()
        try press(48, in: model)
        try press(125, in: model)
        XCTAssertEqual(model.draft.location, first.id)
        XCTAssertNil(model.document.bookmarks.first?.groupId)
        try press(36, in: model)
        XCTAssertEqual(model.draft.location, second.id)
        XCTAssertNil(model.document.bookmarks.first?.groupId)
        try press(36, in: model)
        try await settle(model)
        XCTAssertEqual(model.document.bookmarks.first?.groupId, second.id)
    }

    func testEditIncludesLocationAndNewFolderFields() async throws {
        let bookmark = Bookmark(title: "原题", url: "https://example.org")
        let model = try await model(BookmarkDocument(bookmarks: [bookmark]))
        model.beginEdit()
        model.updateInput("新题")
        try press(48, in: model)
        XCTAssertEqual(model.prompt?.field, "location")
        try press(48, in: model)
        try press(125, in: model)
        try press(36, in: model)
        try press(48, in: model)
        try press(48, in: model)
        XCTAssertEqual(model.prompt?.field, "folder")
        model.updateInput("归档")
        try press(36, in: model)
        try await settle(model)
        XCTAssertEqual(model.document.bookmarks.count, 1)
        XCTAssertEqual(model.document.bookmarks.first?.title, "新题")
        XCTAssertEqual(model.document.bookmarks.first?.groupId, model.document.groups.first?.id)
        XCTAssertEqual(model.document.groups.first?.name, "归档")
    }
}
