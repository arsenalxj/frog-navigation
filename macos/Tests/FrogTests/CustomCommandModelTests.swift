import AppKit
import XCTest
import FrogCore
@testable import Frog

@MainActor
final class CustomCommandModelTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }
    private func model(_ document: BookmarkDocument = BookmarkDocument()) async throws -> LauncherModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Frog-Command-Model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        if document != BookmarkDocument() { try document.encoded().write(to: directory.appendingPathComponent("bookmarks.json")) }
        let store = BookmarkStore(directoryOverride: directory, persistDirectory: false)
        await store.load()
        let model = LauncherModel(store: store, isolated: true)
        await model.customLoadTask?.value
        return model
    }
    private func wait(_ condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    private func event(_ code: UInt16, _ text: String = "", _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: 0, context: nil, characters: text,
                                      charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }
    private func add(_ model: LauncherModel, name: String = "literal") async throws {
        model.openCustomCommands()
        model.beginCustomEdit()
        model.customDraft = CustomCommand(name: name, title: "参数原样输出", type: .program,
                                          directory: model.store.directory.path, target: "/usr/bin/printf",
                                          arguments: "'%s' {args}", terminal: .none)
        model.showCustomField()
        model.saveCustomDraft()
        try await wait { !model.customSaving }
        XCTAssertEqual(model.customCommands.map(\.name), [name])
    }
    func testFieldSwitchRetainsDraftAndEscapeDoesNotPersist() async throws {
        let model = try await model()
        try await add(model)
        model.beginCustomEdit(try XCTUnwrap(model.selectedCustomCommand))
        model.updateInput("renamed")
        model.moveCustomField(1)
        model.updateInput("未保存的标题")
        model.moveCustomField(-1)
        XCTAssertEqual(model.inputText, "renamed")
        model.escape()
        let saved = try await model.customStore.load(reservedNames: LauncherModel.reservedCommandNames)
        XCTAssertEqual(saved.first?.name, "literal")
        XCTAssertEqual(saved.first?.title, "参数原样输出")
        XCTAssertNil(model.prompt)
        XCTAssertEqual(model.customScreen, .list)
    }
    func testDuplicateSavePreservesDraftAndStoredCommands() async throws {
        let model = try await model()
        try await add(model)
        model.beginCustomEdit(try XCTUnwrap(model.selectedCustomCommand), copy: true)
        model.updateInput("LITERAL")
        model.saveCustomDraft()
        try await wait { !model.customSaving }
        XCTAssertEqual(model.customScreen, .edit)
        XCTAssertNotNil(model.prompt?.error)
        XCTAssertEqual(model.customDraft?.name, "LITERAL")
        let saved = try await model.customStore.load(reservedNames: LauncherModel.reservedCommandNames)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.name, "literal")
    }
    func testExplicitCandidateRequiredAndRuntimeArgumentsRemainData() async throws {
        let model = try await model()
        try await add(model)
        model.startCommand()
        model.updateInput("lit")
        model.submitInput()
        XCTAssertFalse(model.customExecuting)
        XCTAssertNil(model.customExecutionCommand)
        model.startCommand()
        model.updateInput("参数原样")
        XCTAssertTrue(model.handleKey(try event(125), isTextEditing: true))
        XCTAssertEqual(model.commandCandidates[try XCTUnwrap(model.commandCandidateIndex)].name, "literal")
        model.completeCommand(backward: false)
        XCTAssertEqual(model.inputText, "literal")
        let payload = "中文 ' ; $(touch injected) & \" x"
        model.updateInput("literal " + payload)
        model.submitInput()
        try await wait { !model.customExecuting }
        XCTAssertEqual(model.customExecutionOutput, [payload])
        XCTAssertFalse(model.customExecutionFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.store.directory.appendingPathComponent("injected").path))
    }
    func testDeleteCancellationAndConfirmationAffectOnlyConfiguration() async throws {
        let model = try await model()
        try await add(model)
        let bookmarkData = try Data(contentsOf: model.store.directory.appendingPathComponent("bookmarks.json"))
        model.requestCustomDelete()
        XCTAssertTrue(model.handleKey(try event(45, "n"), isTextEditing: false))
        XCTAssertEqual(model.customCommands.count, 1)
        model.requestCustomDelete()
        XCTAssertTrue(model.handleKey(try event(16, "y"), isTextEditing: false))
        try await wait { !model.customSaving }
        XCTAssertTrue(model.customCommands.isEmpty)
        let saved = try await model.customStore.load(reservedNames: LauncherModel.reservedCommandNames)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(try Data(contentsOf: model.store.directory.appendingPathComponent("bookmarks.json")), bookmarkData)
    }
    func testDirectoryBrowseModesTraverseAndConfirmWithoutSavingEarly() async throws {
        let model = try await model()
        let root = model.store.directory
        for path in ["work", "alpha", "alpine/中文 空格 ' &", "beta", ".hidden"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: root.appendingPathComponent("alpha.json"))
        model.beginCustomEdit(CustomCommand(name: "aiomp", title: "项目", directory: root.appendingPathComponent("work").path, target: "omp"))
        model.selectCustomField(try XCTUnwrap(model.customFields.firstIndex(of: .directory)))
        model.updateInput("../")
        await model.completionTask?.value
        XCTAssertEqual(Set(model.prompt?.choices.map { URL(fileURLWithPath: $0.label).lastPathComponent } ?? []), Set(["work", "alpha", "alpine", "beta"]))
        XCTAssertFalse(model.customDirectoryBrowsing, "进入字段不自动进入浏览")
        XCTAssertTrue(model.handleKey(try event(36, "\r"), isTextEditing: true))
        await model.completionTask?.value
        XCTAssertTrue(model.customDirectoryBrowsing, "Enter 才进入目录浏览")
        XCTAssertEqual(model.customField, .directory)
        let browsingText = model.inputText
        XCTAssertTrue(model.handleKey(try event(36, "\r"), isTextEditing: true))
        XCTAssertFalse(model.customDirectoryBrowsing, "Enter 退出浏览")
        XCTAssertEqual(model.inputText, browsingText, "Enter 不应用高亮目录，路径保持不变")
        XCTAssertTrue(model.handleKey(try event(36, "\r"), isTextEditing: true))
        await model.completionTask?.value
        XCTAssertTrue(model.customDirectoryBrowsing, "再次 Enter 回到浏览")
        XCTAssertTrue(model.handleKey(try event(125), isTextEditing: true))
        XCTAssertEqual(model.inputText, browsingText, "浏览中方向键只移动候选，不改输入")
        XCTAssertEqual(model.customField, .directory, "浏览中方向键不切字段")
        XCTAssertEqual(model.prompt?.selectedChoice, 1)
        XCTAssertTrue(model.handleKey(try event(126), isTextEditing: true))
        XCTAssertEqual(model.prompt?.selectedChoice, 0)
        XCTAssertTrue(model.handleKey(try event(48, "\t"), isTextEditing: true))
        await model.completionTask?.value
        XCTAssertEqual(model.inputText, root.appendingPathComponent("alpha").path + "/", "Tab 选择并进入目录")
        XCTAssertTrue(model.customDirectoryBrowsing)
        XCTAssertTrue(model.handleKey(try event(48, "\t", .shift), isTextEditing: true))
        await model.completionTask?.value
        XCTAssertEqual(model.inputText, root.path + "/", "Shift+Tab 返回上一级")
        XCTAssertEqual(model.prompt?.choices.map(\.label).first, root.appendingPathComponent("alpha").path + "/", "返回后预选刚才的目录")
        XCTAssertTrue(model.handleKey(try event(125), isTextEditing: true))
        XCTAssertTrue(model.handleKey(try event(48, "\t"), isTextEditing: true))
        await model.completionTask?.value
        let chosen = root.appendingPathComponent("alpine/中文 空格 ' &").path
        XCTAssertEqual(model.inputText, root.appendingPathComponent("alpine").path + "/")
        XCTAssertTrue(model.handleKey(try event(48, "\t"), isTextEditing: true))
        await model.completionTask?.value
        XCTAssertEqual(model.inputText, chosen + "/", "Tab 继续进入子目录")
        XCTAssertTrue(model.handleKey(try event(36, "\r"), isTextEditing: true))
        XCTAssertFalse(model.customDirectoryBrowsing, "Enter 退出浏览并保留 Tab 选中的路径")
        XCTAssertEqual(model.inputText, chosen + "/")
        XCTAssertTrue(model.handleKey(try event(125), isTextEditing: true))
        XCTAssertEqual(model.customField, .target, "字段模式下方向键恢复切字段")
        XCTAssertEqual(model.customDraft?.directory, chosen + "/")
        XCTAssertTrue(model.customCommands.isEmpty)
        let before = try await model.customStore.load(reservedNames: LauncherModel.reservedCommandNames)
        XCTAssertTrue(before.isEmpty)
        model.saveCustomDraft()
        try await wait { !model.customSaving }
        let after = try await model.customStore.load(reservedNames: LauncherModel.reservedCommandNames)
        XCTAssertEqual(after.first?.directory, chosen)
        XCTAssertEqual(after.first?.target, "omp")
    }

    func testEscapeLeavesBrowseWithoutCancellingEditAndTypingResumesFiltering() async throws {
        let model = try await model()
        let root = model.store.directory
        for name in ["alpha", "alpine"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        model.beginCustomEdit(CustomCommand(name: "aiomp", title: "项目", directory: root.path, target: "omp"))
        model.selectCustomField(try XCTUnwrap(model.customFields.firstIndex(of: .directory)))
        let origin = model.inputText
        XCTAssertTrue(model.handleKey(try event(36, "\r"), isTextEditing: true))
        XCTAssertTrue(model.customDirectoryBrowsing)
        XCTAssertTrue(model.handleKey(try event(125), isTextEditing: true))
        XCTAssertTrue(model.handleKey(try event(53), isTextEditing: true))
        XCTAssertFalse(model.customDirectoryBrowsing, "Esc 仅退出浏览")
        XCTAssertEqual(model.inputText, origin, "退出浏览恢复进入前路径")
        XCTAssertNotNil(model.prompt, "编辑未被取消")
        XCTAssertTrue(model.handleKey(try event(36, "\r"), isTextEditing: true))
        XCTAssertTrue(model.customDirectoryBrowsing)
        model.updateInput(origin + "a")
        XCTAssertFalse(model.customDirectoryBrowsing, "字段编辑器键入退出浏览并保留新输入")
        XCTAssertEqual(model.inputText, origin + "a")
        XCTAssertTrue(model.handleKey(try event(53), isTextEditing: true))
        XCTAssertNil(model.prompt, "第二次 Esc 取消整次编辑")
        XCTAssertFalse(model.customDirectoryBrowsing)
    }

    func testDirectoryValidationKeepsInputAndEscapePreservesSavedCommand() async throws {
        let model = try await model()
        try await add(model)
        let original = try XCTUnwrap(model.selectedCustomCommand)
        model.beginCustomEdit(original)
        model.selectCustomField(try XCTUnwrap(model.customFields.firstIndex(of: .directory)))
        for value in ["missing-folder", "bookmarks.json", "https://example.com/folder"] {
            model.updateInput(value)
            XCTAssertTrue(model.handleKey(try event(36, "\r", .command), isTextEditing: true))
            XCTAssertEqual(model.inputText, value)
            XCTAssertEqual(model.customField, .directory)
            XCTAssertNotNil(model.prompt?.error)
        }
        XCTAssertEqual(try model.resolvedCustomDirectory("~/").path, NSHomeDirectory())
        model.escape()
        XCTAssertNil(model.prompt)
        XCTAssertFalse(model.customDirectoryLoading)
        let saved = try await model.customStore.load(reservedNames: LauncherModel.reservedCommandNames)
        XCTAssertEqual(saved, [original])
    }

    func testDirectoryCandidatesCannotOverwriteNewInputOrAnotherField() async throws {
        let model = try await model()
        let root = model.store.directory
        for name in ["alpha", "beta"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        model.beginCustomEdit(CustomCommand(name: "aiomp", title: "项目", directory: root.path, target: "omp"))
        model.selectCustomField(try XCTUnwrap(model.customFields.firstIndex(of: .directory)))
        model.updateInput("al")
        let obsolete = model.completionTask
        model.updateInput("be")
        await obsolete?.value
        await model.completionTask?.value
        XCTAssertEqual(model.prompt?.choices.map(\.label), [root.appendingPathComponent("beta").path + "/"])
        model.updateInput("al")
        let pending = model.completionTask
        model.moveCustomField(-1)
        await pending?.value
        XCTAssertEqual(model.customField, .type)
        XCTAssertTrue(model.prompt?.choices.isEmpty == true)
        XCTAssertFalse(model.customDirectoryLoading)
        model.moveCustomField(1)
        model.updateInput("be")
        let cancelled = model.completionTask
        model.escape()
        await cancelled?.value
        XCTAssertNil(model.prompt)
        XCTAssertFalse(model.customDirectoryLoading)
    }

    func testArrowsSwitchFieldsAndEnterEntersDirectoryBrowse() async throws {
        let model = try await model()
        let root = model.store.directory
        try FileManager.default.createDirectory(at: root.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        model.beginCustomEdit(CustomCommand(name: "aiomp", title: "项目", directory: root.path, target: "omp", terminal: .terminal))
        let fields = model.customFields
        _ = model.handleKey(try event(126), isTextEditing: true)
        XCTAssertEqual(model.customField, .name)
        for index in 0..<3 {
            XCTAssertEqual(model.customField, fields[index])
            XCTAssertTrue(model.handleKey(try event(36, "\r"), isTextEditing: true))
            XCTAssertEqual(model.customField, fields[index + 1], "字段模式下 Enter 进入下一字段")
        }
        XCTAssertEqual(model.customField, .directory)
        XCTAssertFalse(model.customDirectoryBrowsing, "Enter 到目录字段不会自动进入浏览")
        let beforeEnter = model.inputText
        XCTAssertTrue(model.handleKey(try event(125), isTextEditing: true))
        XCTAssertEqual(model.customField, .target, "字段模式下方向键继续切字段")
        XCTAssertFalse(model.customDirectoryBrowsing)
        XCTAssertTrue(model.handleKey(try event(126), isTextEditing: true))
        XCTAssertEqual(model.customField, .directory)
        XCTAssertEqual(model.inputText, beforeEnter, "切换字段不改动目录输入")
        XCTAssertTrue(model.handleKey(try event(36, "\r"), isTextEditing: true))
        XCTAssertTrue(model.customDirectoryBrowsing, "在工作目录字段按 Enter 才进入浏览")
        XCTAssertEqual(model.customField, .directory)
        XCTAssertEqual(model.inputText, beforeEnter)
        let browsingText = model.inputText
        XCTAssertTrue(model.handleKey(try event(125), isTextEditing: true))
        XCTAssertEqual(model.inputText, browsingText, "浏览中方向键选候选，不改输入")
        XCTAssertEqual(model.customField, .directory, "浏览中方向键不改字段")
        XCTAssertEqual(model.customDraft?.type, .terminal)
        XCTAssertEqual(model.customDraft?.terminal, .terminal)
        XCTAssertTrue(model.handleKey(try event(53), isTextEditing: true))
        XCTAssertFalse(model.customDirectoryBrowsing)
        XCTAssertEqual(model.inputText, beforeEnter)
        _ = model.handleKey(try event(53), isTextEditing: true)
        XCTAssertNil(model.prompt)
    }

    func testUnavailableSavedTerminalIsPreservedAndExcludedFromAvailableChoices() async throws {
        let model = try await model()
        model.openCustomCommands()
        let original = CustomCommand(name: "aiomp", title: "项目", directory: model.store.directory.path, target: "omp", terminal: .iTerm2)
        model.beginCustomEdit(original)
        model.installedCustomTerminals = [.terminal]
        XCTAssertEqual(model.customTerminalOptions, [.terminal])
        XCTAssertEqual(model.customDraft?.terminal, .iTerm2)
        model.customDraft?.type = .program
        XCTAssertEqual(model.customTerminalOptions, [.none, .terminal])
        model.installedCustomTerminals = []
        XCTAssertEqual(model.customTerminalOptions, [.none])
        model.customDraft?.type = .terminal
        XCTAssertTrue(model.customTerminalOptions.isEmpty)
        XCTAssertEqual(model.customDraft?.terminal, .iTerm2)
    }

    func testForeignPromptFromCommandsBufferStaysUsable() async throws {
        let bookmark = Bookmark(title: "待删", url: "https://example.com/review")
        let model = try await model(BookmarkDocument(bookmarks: [bookmark]))
        model.openCustomCommands()
        model.runCommand("delete")
        XCTAssertEqual(model.prompt?.command, "delete")
        XCTAssertTrue(model.handleKey(try event(16, "y"), isTextEditing: false))
        try await wait { !model.busy && model.document.bookmarks.isEmpty }
        XCTAssertNil(model.customExecutionCommand, "不应执行屏幕上选中的自定义命令")
    }

    func testFilePromptFromCommandsBufferSubmitsOnce() async throws {
        let model = try await model()
        let target = model.store.directory.deletingLastPathComponent()
            .appendingPathComponent("frog-cd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        model.openCustomCommands()
        model.runCommand("cd \(target.path)")
        try await wait { model.store.directory.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() }
        XCTAssertNil(model.prompt)
        XCTAssertEqual(model.job?.status, .success)
    }

    func testWheelScrollKeepsSelectedCommandVisible() async throws {
        let model = try await model()
        model.customCommands = (0..<30).map {
            CustomCommand(name: "c\($0)", title: "命令 \($0)", directory: NSHomeDirectory(), target: "omp")
        }
        model.openCustomCommands()
        model.scroll(rows: 10)
        XCTAssertEqual(model.bufferOffset, 10)
        XCTAssertTrue((10..<26).contains(model.customIndex), "滚轮后选中项仍在可视窗口内")
    }

    func testAscendPreselectsDirectoryItLeft() async throws {
        let model = try await model()
        let root = model.store.directory
        for name in ["alpha", "alpine", "beta"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        model.beginCustomEdit(CustomCommand(name: "browse", title: "预选", directory: root.path, target: "omp"))
        model.selectCustomField(try XCTUnwrap(model.customFields.firstIndex(of: .directory)))
        _ = model.handleKey(try event(36, "\r"), isTextEditing: true)
        await model.completionTask?.value
        _ = model.handleKey(try event(125), isTextEditing: true)
        _ = model.handleKey(try event(125), isTextEditing: true)
        XCTAssertEqual(model.prompt?.selectedChoice, 2)
        _ = model.handleKey(try event(48, "\t"), isTextEditing: true)
        await model.completionTask?.value
        XCTAssertEqual(model.inputText, root.appendingPathComponent("beta").path + "/")
        _ = model.handleKey(try event(48, "\t", .shift), isTextEditing: true)
        await model.completionTask?.value
        XCTAssertEqual(model.prompt?.selectedChoice, 2, "返回后预选刚离开的目录")
        XCTAssertEqual(model.prompt?.choices[2].label, root.appendingPathComponent("beta").path + "/")
    }

    func testEscapeTerminatesBackgroundProgram() async throws {
        let model = try await model()
        model.openCustomCommands()
        model.beginCustomEdit()
        model.customDraft = CustomCommand(name: "slow", title: "长任务", type: .program,
                                          directory: model.store.directory.path, target: "/bin/sleep",
                                          arguments: "{args}", terminal: .none)
        model.showCustomField()
        model.saveCustomDraft()
        try await wait { !model.customSaving }
        let command = try XCTUnwrap(model.customCommands.first)
        model.executeCustomCommand(command, input: "30")
        try await wait { model.customExecuting }
        XCTAssertTrue(model.handleKey(try event(53), isTextEditing: false))
        try await wait { !model.customExecuting }
        XCTAssertTrue(model.customExecutionFailed)
        XCTAssertNotNil(model.customExecutionCommand)
    }

    func testPathChoicesListTypedDotDirectory() async throws {
        let model = try await model()
        let root = model.store.directory
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for name in ["one", "two"] {
            try FileManager.default.createDirectory(at: sub.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let choices = LauncherModel.pathChoices(text: sub.path + "/.", command: "commands-directory", base: root)
        XCTAssertEqual(Set(choices.map { URL(fileURLWithPath: $0.label).lastPathComponent }), ["one", "two"])
        let parentChoices = LauncherModel.pathChoices(text: sub.path + "/..", command: "commands-directory", base: root)
        XCTAssertTrue(parentChoices.contains { URL(fileURLWithPath: $0.label).lastPathComponent == "sub" })
    }
}
