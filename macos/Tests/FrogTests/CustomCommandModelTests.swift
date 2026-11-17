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
    func testProgramSwitchesToDirectoryWithTerminalAndPersistsOnlyVisibleFields() async throws {
        let model = try await model()
        try await add(model)
        model.beginCustomEdit(try XCTUnwrap(model.selectedCustomCommand))
        model.installedCustomTerminals = [.ghostty, .terminal]
        XCTAssertEqual(model.customDraft?.terminal, CustomCommandTerminal.none)
        model.selectCustomField(try XCTUnwrap(model.customFields.firstIndex(of: .type)))
        model.cycleCustomOption(1)
        XCTAssertEqual(model.customDraft?.type, .url)
        model.cycleCustomOption(1)
        XCTAssertEqual(model.customDraft?.type, .directory)
        XCTAssertEqual(model.customDraft?.terminal, .ghostty)
        XCTAssertEqual(model.customTerminalOptions, [.ghostty, .terminal, .finder])
        XCTAssertEqual(model.customFields, [.name, .title, .type, .directory, .terminal])
        model.moveCustomField(1)
        XCTAssertEqual(model.customField, .directory)
        model.moveCustomField(1)
        XCTAssertEqual(model.customField, .terminal)
        model.moveCustomField(-1)
        XCTAssertEqual(model.customField, .directory)
        model.saveCustomDraft()
        try await wait { !model.customSaving }
        XCTAssertNil(model.prompt)
        XCTAssertEqual(model.customScreen, .list)
        model.loadCustomCommands()
        await model.customLoadTask?.value
        let saved = try XCTUnwrap(model.selectedCustomCommand)
        XCTAssertEqual(model.customCommands.count, 1)
        XCTAssertEqual(saved.type, .directory)
        XCTAssertEqual(saved.directory, model.store.directory.path)
        XCTAssertEqual(saved.terminal, .ghostty)
        XCTAssertEqual(saved.target, "")
        XCTAssertEqual(saved.arguments, "")
        model.beginCustomEdit(saved)
        XCTAssertEqual(model.customFields, [.name, .title, .type, .directory, .terminal])
        model.escape()
    }

    func testFinderDirectorySavesAndReloadsWithoutTerminal() async throws {
        let model = try await model()
        model.openCustomCommands()
        model.beginCustomEdit()
        let command = CustomCommand(name: "finder-folder", title: "项目目录", type: .directory,
                                    directory: model.store.directory.path, target: "", terminal: .finder)
        model.customDraft = command
        model.showCustomField()
        model.installedCustomTerminals = []
        XCTAssertEqual(model.customTerminalOptions, [.finder])
        model.saveCustomDraft()
        try await wait { !model.customSaving }
        XCTAssertNil(model.prompt)
        XCTAssertEqual(model.customScreen, .list)
        model.loadCustomCommands()
        await model.customLoadTask?.value
        XCTAssertEqual(model.customCommands, [command])
        model.beginCustomEdit(try XCTUnwrap(model.selectedCustomCommand))
        XCTAssertEqual(model.customDraft?.terminal, .finder)
        XCTAssertEqual(model.customFields, [.name, .title, .type, .directory, .terminal])
        model.escape()
    }

    func testFinderIsClearedWhenSwitchingToNonDirectoryKinds() async throws {
        let model = try await model()
        let cases: [(Int, CustomCommandKind, CustomCommandTerminal)] = [
            (1, .terminal, .ghostty), (2, .program, .none), (-1, .url, .none)
        ]
        for (direction, kind, terminal) in cases {
            model.beginCustomEdit(CustomCommand(name: "folder", title: "项目目录", type: .directory,
                                                directory: model.store.directory.path, target: "", terminal: .finder))
            model.installedCustomTerminals = [.ghostty, .terminal]
            model.selectCustomField(try XCTUnwrap(model.customFields.firstIndex(of: .type)))
            model.cycleCustomOption(direction)
            XCTAssertEqual(model.customDraft?.type, kind)
            XCTAssertEqual(model.customDraft?.terminal, terminal)
            XCTAssertFalse(model.customTerminalOptions.contains(.finder))
            model.escape()
        }
    }

    func testDirectoryCommandRejectsMissingFolderAndRegularFileOnSave() async throws {
        let model = try await model()
        let file = model.store.directory.appendingPathComponent("普通文件")
        try Data().write(to: file)
        model.beginCustomEdit(CustomCommand(name: "folder", title: "打开项目", type: .directory,
                                            directory: model.store.directory.path, target: "", terminal: .terminal))
        model.selectCustomField(try XCTUnwrap(model.customFields.firstIndex(of: .directory)))
        for path in [model.store.directory.appendingPathComponent("不存在的目录").path, file.path] {
            model.updateInput(path)
            model.saveCustomDraft()
            try await wait { !model.customSaving }
            XCTAssertEqual(model.customScreen, .edit)
            XCTAssertNotNil(model.prompt?.error)
            XCTAssertEqual(model.inputText, path)
            XCTAssertTrue(model.customCommands.isEmpty)
        }
        let saved = try await model.customStore.load(reservedNames: LauncherModel.reservedCommandNames)
        XCTAssertTrue(saved.isEmpty)
        model.escape()
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
        XCTAssertEqual(model.buffer, .commands)
        XCTAssertEqual(model.customScreen, .execution)
        try await wait { !model.customExecuting }
        XCTAssertEqual(model.customExecutionOutput, [payload])
        XCTAssertFalse(model.customExecutionFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.store.directory.appendingPathComponent("injected").path))
    }

    func testHomeCommandExecutionPreservesPageOnSuccessAndFailure() async throws {
        let model = try await model()
        try await add(model)
        model.escape()
        XCTAssertNil(model.buffer)
        for (name, target, fails) in [("literal", "/usr/bin/printf", false),
                                      ("missing", model.store.directory.appendingPathComponent("missing").path, true)] {
            model.customCommands = [CustomCommand(name: name, title: "直接执行", type: .program,
                                                 directory: model.store.directory.path, target: target,
                                                 arguments: "'%s' {args}", terminal: .none)]
            model.startCommand()
            model.updateInput(name + " 首页执行")
            model.submitInput()
            XCTAssertNil(model.buffer)
            XCTAssertEqual(model.customScreen, .list)
            XCTAssertNil(model.inputKind)
            try await wait { !model.customExecuting }
            XCTAssertNil(model.buffer)
            XCTAssertEqual(model.customExecutionFailed, fails)
            if !fails { XCTAssertEqual(model.customExecutionOutput, ["首页执行"]) }
        }
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

    func testDeleteConfirmationKeepsCapturedTargetAcrossHideAndFilterReset() async throws {
        for filtered in [false, true] {
            let model = try await model()
            let commands = ["first", "second"].map {
                CustomCommand(name: $0, title: $0, type: .directory, directory: model.store.directory.path, terminal: .finder)
            }
            try await model.customStore.save(commands, reservedNames: LauncherModel.reservedCommandNames)
            model.loadCustomCommands()
            await model.customLoadTask?.value
            model.openCustomCommands()
            if filtered { model.startCustomSearch(); model.updateInput("second") }
            model.selectCustomCommand(filtered ? 0 : 1)
            model.requestCustomDelete()
            model.didHide()
            XCTAssertEqual(model.selectedCustomCommand?.name, "first")
            XCTAssertEqual(model.customDisplayedCommand, commands[1])
            model.requestCustomDelete()
            XCTAssertEqual(model.customDisplayedCommand, commands[1])
            XCTAssertTrue(model.handleKey(try event(16, "y"), isTextEditing: false))
            try await wait { !model.customSaving }
            let saved = try await model.customStore.load(reservedNames: LauncherModel.reservedCommandNames)
            XCTAssertEqual(saved, [commands[0]])
        }
    }
    func testDirectoryCandidatesBrowseWithoutChangingDraftAndEnterAdopts() async throws {
        let model = try await model()
        let root = model.store.directory
        for path in ["work", "alpha", "alpine/中文 空格 ' &", "beta", ".hidden"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: root.appendingPathComponent("alpha.json"))
        model.beginCustomEdit(CustomCommand(name: "aiomp", title: "项目", directory: root.appendingPathComponent("work").path, target: "omp"))
        model.selectCustomField(try XCTUnwrap(model.customFields.firstIndex(of: .directory)))
        model.updateInput("../")
        XCTAssertTrue(model.prompt?.choices.isEmpty == true)
        XCTAssertTrue(model.handleKey(try event(125, "", .command), isTextEditing: true))
        await model.completionTask?.value
        XCTAssertEqual(model.prompt?.choices.first?.detail, "current-directory")
        XCTAssertEqual(Set(model.prompt?.choices.dropFirst().map { URL(fileURLWithPath: $0.label).lastPathComponent } ?? []), Set(["work", "alpha", "alpine", "beta"]))
        XCTAssertTrue(model.customDirectoryFocused)
        XCTAssertFalse(model.isTextInputActive)
        let alpine = try XCTUnwrap(model.prompt?.choices.firstIndex { $0.label == root.appendingPathComponent("alpine").path + "/" })
        model.chooseCustomDirectoryCandidate(at: alpine)
        XCTAssertTrue(model.handleKey(try event(124), isTextEditing: false))
        await model.completionTask?.value
        XCTAssertEqual(model.customDirectoryPath, root.appendingPathComponent("alpine").path + "/")
        XCTAssertEqual(model.inputText, "../")
        XCTAssertEqual(model.customDraft?.directory, "../")
        XCTAssertTrue(model.handleKey(try event(125), isTextEditing: false))
        let chosen = root.appendingPathComponent("alpine/中文 空格 ' &").path
        XCTAssertTrue(model.handleKey(try event(36, "\r"), isTextEditing: false))
        XCTAssertFalse(model.customDirectoryFocused)
        XCTAssertEqual(model.inputText, chosen)
        XCTAssertEqual(model.customDraft?.directory, chosen)
        XCTAssertTrue(model.prompt?.choices.isEmpty == true)
        XCTAssertTrue(model.isTextInputActive)
        XCTAssertTrue(model.handleKey(try event(48, "\t"), isTextEditing: true))
        XCTAssertEqual(model.customField, .target)
        XCTAssertFalse(model.customDirectoryFocused)
        XCTAssertTrue(model.handleKey(try event(48, "\t", .shift), isTextEditing: true))
        XCTAssertEqual(model.customField, .directory)
        XCTAssertFalse(model.customDirectoryFocused)
        XCTAssertEqual(model.inputText, chosen)
        XCTAssertTrue(model.customCommands.isEmpty)
        XCTAssertTrue(model.handleKey(try event(36, "\r"), isTextEditing: true))
        try await wait { !model.customSaving }
        let saved = try await model.customStore.load(reservedNames: LauncherModel.reservedCommandNames)
        XCTAssertEqual(saved.first?.directory, chosen)
        XCTAssertEqual(saved.first?.target, "omp")
    }

    func testDirectoryEscapeAndTabDiscardOnlyCandidateBrowsing() async throws {
        let model = try await model()
        let root = model.store.directory
        try FileManager.default.createDirectory(at: root.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        model.beginCustomEdit(CustomCommand(name: "aiomp", title: "项目", directory: root.path, target: "omp"))
        model.selectCustomField(try XCTUnwrap(model.customFields.firstIndex(of: .directory)))
        let origin = model.inputText
        for leavingKey in [UInt16(53), UInt16(48)] {
            model.focusCustomDirectoryChoices()
            await model.completionTask?.value
            model.moveCustomDirectoryChoice(1)
            model.openCustomDirectoryChoice()
            await model.completionTask?.value
            XCTAssertEqual(model.inputText, origin)
            model.updateInput("ignored while candidates own focus")
            XCTAssertEqual(model.inputText, origin)
            XCTAssertTrue(model.handleKey(try event(leavingKey), isTextEditing: false))
            XCTAssertFalse(model.customDirectoryFocused)
            XCTAssertEqual(model.customDraft?.directory, origin)
            XCTAssertNotNil(model.prompt)
            if leavingKey == 48 {
                XCTAssertEqual(model.customField, .target)
                XCTAssertTrue(model.handleKey(try event(48, "\t", .shift), isTextEditing: true))
                XCTAssertFalse(model.customDirectoryFocused)
            }
            XCTAssertEqual(model.customField, .directory)
            XCTAssertEqual(model.inputText, origin)
        }
        model.updateInput(origin + "/a")
        XCTAssertEqual(model.customDraft?.directory, origin + "/a")
        XCTAssertTrue(model.handleKey(try event(53), isTextEditing: true))
        XCTAssertNil(model.prompt)
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

    func testDirectoryReadCannotReopenClosedBrowserOrOverwriteNewInput() async throws {
        let model = try await model()
        let root = model.store.directory
        for name in ["alpha", "beta"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        model.beginCustomEdit(CustomCommand(name: "aiomp", title: "项目", directory: root.path, target: "omp"))
        model.selectCustomField(try XCTUnwrap(model.customFields.firstIndex(of: .directory)))
        model.updateInput("al")
        model.focusCustomDirectoryChoices()
        let obsolete = model.completionTask
        model.escape()
        model.updateInput("be")
        await obsolete?.value
        XCTAssertFalse(model.customDirectoryFocused)
        XCTAssertTrue(model.prompt?.choices.isEmpty == true)
        XCTAssertEqual(model.inputText, "be")
        model.focusCustomDirectoryChoices()
        await model.completionTask?.value
        XCTAssertEqual(model.prompt?.choices.filter { $0.detail != "current-directory" }.map(\.label), [root.appendingPathComponent("beta").path + "/"])
        model.refreshCustomDirectoryChoices()
        let pending = model.completionTask
        _ = model.handleKey(try event(48, "\t", .shift), isTextEditing: false)
        await pending?.value
        XCTAssertEqual(model.customField, .type)
        XCTAssertTrue(model.prompt?.choices.isEmpty == true)
        XCTAssertFalse(model.customDirectoryLoading)
        model.moveCustomField(1)
        model.focusCustomDirectoryChoices()
        let cancelled = model.completionTask
        model.escape()
        await cancelled?.value
        XCTAssertNotNil(model.prompt)
        XCTAssertFalse(model.customDirectoryLoading)
        XCTAssertTrue(model.prompt?.choices.isEmpty == true)
    }

    func testTabSwitchesFieldsAndArrowsPreserveNativeTextEditing() async throws {
        let model = try await model()
        model.beginCustomEdit(CustomCommand(name: "aiomp", title: "项目", directory: model.store.directory.path, target: "omp"))
        model.updateInput("renamed")
        for modifiers in [NSEvent.ModifierFlags(), .shift, .option, .command] {
            for code in [UInt16(125), UInt16(126)] {
                XCTAssertFalse(model.handleCustomCommandKey(try event(code, "", modifiers), isTextEditing: true))
                XCTAssertEqual(model.customField, .name)
                XCTAssertEqual(model.inputText, "renamed")
            }
        }
        XCTAssertTrue(model.handleKey(try event(48, "\t"), isTextEditing: true))
        XCTAssertEqual(model.customField, .title)
        model.updateInput("未保存标题")
        XCTAssertTrue(model.handleKey(try event(48, "\t", .shift), isTextEditing: true))
        XCTAssertEqual(model.inputText, "renamed")
        XCTAssertEqual(model.customDraft?.title, "未保存标题")
        XCTAssertTrue(model.customCommands.isEmpty)
        XCTAssertTrue(model.handleKey(try event(36, "\r"), isTextEditing: true))
        try await wait { !model.customSaving }
        XCTAssertEqual(model.customCommands.first?.name, "renamed")
        XCTAssertEqual(model.customCommands.first?.title, "未保存标题")
    }

    func testDirectoryActionTabNeverEntersCandidatesAndAcceptClosesThem() async throws {
        let model = try await model()
        let root = model.store.directory
        let child = root.appendingPathComponent("工作目录")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        model.beginCustomEdit(CustomCommand(name: "browse", title: "目录", type: .directory, directory: root.path, terminal: .finder))
        for field in model.customFields.dropFirst() {
            _ = model.handleKey(try event(48, "\t"), isTextEditing: model.isTextInputActive)
            XCTAssertEqual(model.customField, field)
            XCTAssertFalse(model.customDirectoryFocused)
        }
        _ = model.handleKey(try event(48, "\t", .shift), isTextEditing: false)
        XCTAssertEqual(model.customField, .directory)
        XCTAssertTrue(model.isTextInputActive)
        XCTAssertTrue(model.prompt?.choices.isEmpty == true)
        _ = model.handleKey(try event(125, "", .command), isTextEditing: true)
        await model.completionTask?.value
        _ = model.handleKey(try event(125), isTextEditing: false)
        _ = model.handleKey(try event(36), isTextEditing: false)
        XCTAssertEqual(model.customField, .directory)
        XCTAssertEqual(model.inputText, child.path)
        XCTAssertTrue(model.isTextInputActive)
        XCTAssertTrue(model.prompt?.choices.isEmpty == true)
        _ = model.handleKey(try event(48, "\t"), isTextEditing: true)
        XCTAssertEqual(model.customField, .terminal)
        XCTAssertFalse(model.customDirectoryFocused)
        _ = model.handleKey(try event(48, "\t", .shift), isTextEditing: false)
        _ = model.handleKey(try event(125, "", .command), isTextEditing: true)
        _ = model.handleKey(try event(48, "\t", .shift), isTextEditing: false)
        XCTAssertEqual(model.customField, .type)
        XCTAssertEqual(model.customDraft?.directory, child.path)
        XCTAssertFalse(model.customDirectoryFocused)
        XCTAssertTrue(model.customCommands.isEmpty)
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
        model.customDraft?.type = .directory
        XCTAssertEqual(model.customTerminalOptions, [.finder])
        model.installedCustomTerminals = [.ghostty, .terminal]
        XCTAssertEqual(model.customTerminalOptions, [.ghostty, .terminal, .finder])
    }

    func testBookmarkCommandsRejectHiddenObjectsFromCommandsBuffer() async throws {
        let bookmark = Bookmark(title: "不可见书签", url: "https://example.com/review")
        let model = try await model(BookmarkDocument(bookmarks: [bookmark]))
        model.openCustomCommands()
        for command in ["delete", "edit", "move", "open"] {
            model.runCommand(command)
            XCTAssertNil(model.prompt)
            XCTAssertEqual(model.buffer, .commands)
            XCTAssertEqual(model.document.bookmarks, [bookmark])
            XCTAssertNil(model.customExecutionCommand)
        }
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

    func testAscendPreselectsDirectoryItLeftAndCurrentDirectoryCanBeAdopted() async throws {
        let model = try await model()
        let root = model.store.directory
        for name in ["alpha", "alpine", "beta"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        model.beginCustomEdit(CustomCommand(name: "browse", title: "预选", directory: root.path, target: "omp"))
        model.selectCustomField(try XCTUnwrap(model.customFields.firstIndex(of: .directory)))
        model.focusCustomDirectoryChoices()
        await model.completionTask?.value
        model.moveCustomDirectoryChoice(3)
        XCTAssertEqual(model.prompt?.selectedChoice, 3)
        _ = model.handleKey(try event(124), isTextEditing: false)
        await model.completionTask?.value
        XCTAssertEqual(model.customDirectoryPath, root.appendingPathComponent("beta").path + "/")
        XCTAssertEqual(model.inputText, root.path)
        _ = model.handleKey(try event(123), isTextEditing: false)
        await model.completionTask?.value
        XCTAssertEqual(model.prompt?.selectedChoice, 3)
        XCTAssertEqual(model.prompt?.choices[3].label, root.appendingPathComponent("beta").path + "/")
        model.chooseCustomDirectoryCandidate(at: 0, activate: true)
        XCTAssertFalse(model.customDirectoryFocused)
        XCTAssertEqual(model.customDraft?.directory, root.path)
        XCTAssertTrue(model.customCommands.isEmpty)
    }

    func testEscapeReturnsAndOnlyConfirmedStopTerminatesBackgroundProgram() async throws {
        let model = try await model()
        model.openCustomCommands()
        let command = CustomCommand(name: "slow", title: "长任务", type: .program,
                                    directory: model.store.directory.path, target: "/bin/sleep", arguments: "30", terminal: .none)
        defer { if model.customExecuting { model.customExecutor.cancelRunningProgram() } }
        model.executeCustomCommand(command)
        XCTAssertTrue(model.handleKey(try event(53), isTextEditing: false))
        XCTAssertEqual(model.customScreen, .list)
        XCTAssertTrue(model.customExecuting)
        XCTAssertTrue(model.canStopCustomExecution)
        XCTAssertEqual(model.customExecutionCommand, command)
        model.showCustomExecution()
        XCTAssertEqual(model.customScreen, .execution)
        model.escapeCustomCommands()
        XCTAssertTrue(model.customExecuting, "点击返回与 Esc 同样不停止任务")
        for key in [try event(45, "n"), try event(36, "\r"), try event(53)] {
            XCTAssertTrue(model.handleKey(try event(47, ".", .command), isTextEditing: false))
            XCTAssertTrue(model.customStopConfirmation)
            XCTAssertTrue(model.handleKey(key, isTextEditing: false))
            XCTAssertFalse(model.customStopConfirmation)
            XCTAssertTrue(model.customExecuting)
        }
        model.requestCustomStop()
        for (code, text) in [(UInt16(12), "q"), (UInt16(4), "h")] {
            XCTAssertFalse(LauncherKeyRouter.handle(try event(code, text, .command), model: model, firstResponder: nil))
            XCTAssertTrue(model.customStopConfirmation)
            XCTAssertTrue(model.customExecuting)
        }
        for (code, text) in [(UInt16(45), "n"), (UInt16(43), ",")] {
            XCTAssertTrue(model.handleKey(try event(code, text, .command), isTextEditing: false))
            XCTAssertTrue(model.customStopConfirmation)
            XCTAssertNil(model.prompt)
            XCTAssertEqual(model.buffer, .commands)
        }
        XCTAssertTrue(model.handleKey(try event(16, "y"), isTextEditing: false))
        try await wait { !model.customExecuting }
        XCTAssertTrue(model.customExecutionFailed)
        XCTAssertFalse(model.canStopCustomExecution)
        XCTAssertFalse(model.customStopConfirmation)
        XCTAssertNotNil(model.customExecutionCommand)
    }

    func testHomeProgramCanBeStoppedFromCommandsAndNextCommandRuns() async throws {
        let model = try await model()
        let slow = CustomCommand(name: "slow", title: "长任务", type: .program,
                                 directory: model.store.directory.path, target: "/bin/sleep", arguments: "30", terminal: .none)
        let next = CustomCommand(name: "next", title: "下一条", type: .program,
                                 directory: model.store.directory.path, target: "/usr/bin/printf", arguments: "done", terminal: .none)
        model.customCommands = [slow, next]
        defer { if model.customExecuting { model.customExecutor.cancelRunningProgram() } }
        model.runCommand("slow")
        XCTAssertNil(model.buffer)
        XCTAssertTrue(model.customExecuting)
        model.runCommand("commands")
        XCTAssertEqual(model.buffer, .commands)
        XCTAssertEqual(model.customScreen, .execution)
        model.requestCustomStop()
        model.confirmCustomStop()
        try await wait { !model.customExecuting }
        XCTAssertTrue(model.customExecutionFailed)
        model.runCommand("next")
        try await wait { !model.customExecuting }
        XCTAssertEqual(model.customExecutionCommand?.name, "next")
        XCTAssertEqual(model.customExecutionOutput, ["done"])
        XCTAssertFalse(model.customExecutionFailed)
        model.runCommand("commands")
        XCTAssertEqual(model.customScreen, .list)
        model.showCustomExecution()
        XCTAssertEqual(model.customScreen, .execution)
        XCTAssertEqual(model.customExecutionOutput, ["done"])
    }

    func testSearchRetainsFocusRunsSelectionAndEscapeClearsFilter() async throws {
        let model = try await model()
        model.customCommands = ["alpha", "alpine"].map {
            CustomCommand(name: $0, title: $0, type: .program, directory: model.store.directory.path,
                          target: "/usr/bin/printf", arguments: $0, terminal: .none)
        }
        model.openCustomCommands()
        model.startCustomSearch()
        model.updateInput("al")
        XCTAssertTrue(model.handleKey(try event(125), isTextEditing: true))
        XCTAssertEqual(model.inputKind, .search)
        XCTAssertEqual(model.customIndex, 1)
        model.updateInput("alp")
        XCTAssertEqual(model.customQuery, "alp")
        XCTAssertTrue(model.handleKey(try event(125), isTextEditing: true))
        XCTAssertTrue(model.handleKey(try event(48, "\t"), isTextEditing: true))
        XCTAssertNil(model.inputKind)
        XCTAssertEqual(model.selectedCustomCommand?.name, "alpine")
        XCTAssertTrue(model.handleKey(try event(48, "\t", .shift), isTextEditing: false))
        XCTAssertEqual(model.inputKind, .search)
        XCTAssertEqual(model.inputText, "alp")
        XCTAssertTrue(model.handleKey(try event(36, "\r"), isTextEditing: true))
        XCTAssertEqual(model.customScreen, .execution)
        try await wait { !model.customExecuting }
        XCTAssertEqual(model.customExecutionOutput, ["alpine"])
        model.escapeCustomCommands()
        XCTAssertEqual(model.customQuery, "alp")
        model.escapeCustomCommands()
        XCTAssertEqual(model.customQuery, "")
        XCTAssertEqual(model.buffer, .commands)
        model.startCustomSearch()
        model.updateInput("no-match")
        XCTAssertTrue(model.handleKey(try event(48, "\t"), isTextEditing: true))
        XCTAssertEqual(model.inputKind, .search)
        XCTAssertTrue(model.handleKey(try event(36, "\r"), isTextEditing: true))
        XCTAssertFalse(model.customExecuting)
        XCTAssertEqual(model.customScreen, .list)
        XCTAssertTrue(model.handleKey(try event(53), isTextEditing: true))
        XCTAssertNil(model.inputKind)
        XCTAssertEqual(model.customQuery, "")
    }

    func testDuplicateUsesCommandDAndBareCDoesNothing() async throws {
        let model = try await model()
        try await add(model)
        XCTAssertFalse(model.handleCustomCommandKey(try event(8, "c"), isTextEditing: false))
        XCTAssertNil(model.customDraft)
        XCTAssertFalse(model.handleCustomCommandKey(try event(2, "d", [.command, .option]), isTextEditing: false))
        XCTAssertTrue(model.handleKey(try event(2, "d", .command), isTextEditing: false))
        XCTAssertEqual(model.customDraft?.name, "literal-copy")
        XCTAssertNil(model.customOriginalName)
        XCTAssertEqual(model.customCommands.count, 1)
        model.escapeCustomCommands()
        model.startCustomSearch()
        XCTAssertFalse(model.handleCustomCommandKey(try event(2, "d", .command), isTextEditing: true))
        XCTAssertNil(model.customDraft)
        model.escapeCustomCommands()
        XCTAssertTrue(model.handleKey(try event(0, "a"), isTextEditing: false))
        XCTAssertEqual(model.customScreen, .edit)
        model.escapeCustomCommands()
        XCTAssertTrue(model.handleKey(try event(45, "n", .command), isTextEditing: false))
        XCTAssertEqual(model.customScreen, .edit)
    }

    func testCommandEnterDoesNotAdoptHighlightedDirectory() async throws {
        let model = try await model()
        let root = model.store.directory
        let child = root.appendingPathComponent("未采纳")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        model.beginCustomEdit(CustomCommand(name: "browse", title: "保留草稿", type: .directory, directory: root.path, terminal: .finder))
        model.selectCustomField(try XCTUnwrap(model.customFields.firstIndex(of: .directory)))
        model.focusCustomDirectoryChoices()
        await model.completionTask?.value
        model.moveCustomDirectoryChoice(1)
        model.openCustomDirectoryChoice()
        await model.completionTask?.value
        XCTAssertEqual(model.customDirectoryPath, child.path + "/")
        XCTAssertTrue(model.handleKey(try event(36, "\r", .command), isTextEditing: false))
        try await wait { !model.customSaving }
        XCTAssertEqual(model.customCommands.first?.directory, root.path)
        XCTAssertFalse(model.customDirectoryFocused)
    }

    func testValidationFocusesInvalidFieldAndPreservesOtherDrafts() async throws {
        let model = try await model()
        try await add(model)
        model.beginCustomEdit(try XCTUnwrap(model.selectedCustomCommand))
        model.updateInput("renamed")
        model.selectCustomField(try XCTUnwrap(model.customFields.firstIndex(of: .directory)))
        model.updateInput("not-a-directory")
        model.selectCustomField(try XCTUnwrap(model.customFields.firstIndex(of: .title)))
        model.updateInput("新标题")
        model.saveCustomDraft()
        XCTAssertEqual(model.customField, .directory)
        XCTAssertEqual(model.inputText, "not-a-directory")
        XCTAssertEqual(model.customDraft?.name, "renamed")
        XCTAssertEqual(model.customDraft?.title, "新标题")
        XCTAssertNotNil(model.prompt?.error)
        model.updateInput(model.store.directory.path)
        model.selectCustomField(try XCTUnwrap(model.customFields.firstIndex(of: .name)))
        model.updateInput("1invalid")
        model.selectCustomField(try XCTUnwrap(model.customFields.firstIndex(of: .title)))
        model.saveCustomDraft()
        XCTAssertEqual(model.customField, .name)
        XCTAssertEqual(model.inputText, "1invalid")
        XCTAssertEqual(model.customDraft?.title, "新标题")
        XCTAssertEqual(model.customCommands.first?.name, "literal")
    }

    func testOutputPagingMovesOneVisibleScreenAndExternalHandoffsCannotStop() async throws {
        let model = try await model()
        model.openCustomCommands()
        model.customExecutionCommand = CustomCommand(name: "terminal", title: "外部终端", directory: model.store.directory.path, target: "echo")
        model.customExecutionOutput = (0..<60).map { "行 \($0)" }
        model.showCustomExecution()
        XCTAssertTrue(model.handleKey(try event(121), isTextEditing: false))
        XCTAssertEqual(model.bufferOffset, LauncherModel.calcVisibleRows)
        XCTAssertTrue(model.handleKey(try event(125), isTextEditing: false))
        XCTAssertEqual(model.bufferOffset, LauncherModel.calcVisibleRows + 1)
        XCTAssertTrue(model.handleKey(try event(116), isTextEditing: false))
        XCTAssertEqual(model.bufferOffset, 1)
        for command in [
            CustomCommand(name: "terminal", title: "终端", target: "echo"),
            CustomCommand(name: "web", title: "网页", type: .url, target: "https://example.com"),
            CustomCommand(name: "finder", title: "目录", type: .directory, terminal: .finder)
        ] {
            model.customExecutionCommand = command
            model.customExecuting = true
            XCTAssertFalse(model.canStopCustomExecution)
            model.requestCustomStop()
            XCTAssertFalse(model.customStopConfirmation)
            model.customExecuting = false
        }
    }

    func testClickActionsShareSelectionAcceptanceAndStopContracts() async throws {
        let model = try await model()
        try await add(model)
        let view = LauncherView(model: model)
        model.startCustomSearch()
        model.updateInput("lit")
        view.performCustomAction(.row(0), activate: false)
        XCTAssertNil(model.inputKind)
        XCTAssertEqual(model.customQuery, "lit")
        view.performCustomAction(.duplicate, activate: false)
        XCTAssertEqual(model.customDraft?.name, "literal-copy")
        let child = model.store.directory.appendingPathComponent("选择目录")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        model.selectCustomField(try XCTUnwrap(model.customFields.firstIndex(of: .directory)))
        view.performCustomAction(.browseDirectory, activate: false)
        await model.completionTask?.value
        let choice = try XCTUnwrap(model.prompt?.choices.firstIndex { $0.label == child.path + "/" })
        let origin = model.inputText
        view.performCustomAction(.directoryChoice(choice), activate: false)
        XCTAssertTrue(model.customDirectoryFocused)
        XCTAssertEqual(model.inputText, origin)
        view.perform(.input)
        XCTAssertFalse(model.customDirectoryFocused)
        XCTAssertTrue(model.isTextInputActive)
        XCTAssertEqual(model.inputText, origin)
        view.performCustomAction(.browseDirectory, activate: false)
        await model.completionTask?.value
        view.performCustomAction(.directoryChoice(choice), activate: true)
        XCTAssertFalse(model.customDirectoryFocused)
        XCTAssertEqual(model.inputText, child.path)
        XCTAssertEqual(model.customCommands.count, 1)
        view.performCustomAction(.cancel, activate: false)
        let slow = CustomCommand(name: "slow", title: "点击停止", type: .program,
                                 directory: model.store.directory.path, target: "/bin/sleep", arguments: "30", terminal: .none)
        defer { if model.customExecuting { model.customExecutor.cancelRunningProgram() } }
        model.executeCustomCommand(slow)
        view.performCustomAction(.cancel, activate: false)
        XCTAssertEqual(model.customScreen, .list)
        XCTAssertTrue(model.customExecuting)
        view.performCustomAction(.results, activate: false)
        XCTAssertEqual(model.customScreen, .execution)
        view.performCustomAction(.stop, activate: false)
        XCTAssertTrue(model.customStopConfirmation)
        view.perform(.input)
        XCTAssertNil(model.inputKind)
        XCTAssertTrue(model.customStopConfirmation)
        view.performCustomAction(.edit, activate: false)
        XCTAssertNil(model.customDraft)
        view.performCustomAction(.cancelStop, activate: false)
        XCTAssertTrue(model.customExecuting)
        view.performCustomAction(.stop, activate: false)
        view.performCustomAction(.confirmStop, activate: false)
        try await wait { !model.customExecuting }
        XCTAssertTrue(model.customExecutionFailed)
        view.performCustomAction(.cancel, activate: false)
        view.performCustomAction(.row(0), activate: true)
        XCTAssertEqual(model.customScreen, .execution)
        try await wait { !model.customExecuting }
        XCTAssertEqual(model.customExecutionCommand?.name, "literal")
    }

    func testFailedStartupDoesNotLeaveStopQueuedForNextProgram() async throws {
        let model = try await model()
        model.openCustomCommands()
        let missing = CustomCommand(name: "missing", title: "启动失败", type: .program,
                                    directory: model.store.directory.path, target: model.store.directory.appendingPathComponent("missing").path,
                                    terminal: .none)
        model.executeCustomCommand(missing)
        model.requestCustomStop()
        model.confirmCustomStop()
        try await wait { !model.customExecuting }
        XCTAssertTrue(model.customExecutionFailed)
        let next = CustomCommand(name: "next", title: "下一条", type: .program,
                                 directory: model.store.directory.path, target: "/bin/sleep", arguments: "0.1", terminal: .none)
        model.executeCustomCommand(next)
        try await wait { !model.customExecuting }
        XCTAssertFalse(model.customExecutionFailed)
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
