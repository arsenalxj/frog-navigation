import XCTest
@testable import FrogCore

final class CustomCommandStoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func command(_ name: String = "work") -> CustomCommand {
        CustomCommand(name: name, title: "工作", target: "pwd")
    }

    private func assertSaveFails(_ store: CustomCommandStore, commands: [CustomCommand],
                                 file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await store.save(commands, reservedNames: [])
            XCTFail("保存应失败", file: file, line: line)
        } catch {}
    }

    private func assertLoadFails(_ store: CustomCommandStore,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await store.load(reservedNames: [])
            XCTFail("读取应失败", file: file, line: line)
        } catch {}
    }

    func testMissingFileLoadsEmptyWithoutCreatingSeedsAndRoundTripsAllKinds() async throws {
        let directory = try temporaryDirectory().appendingPathComponent("new-settings")
        let store = CustomCommandStore(directory: directory)
        let empty = try await store.load(reservedNames: [])
        XCTAssertEqual(empty, [])
        let url = directory.appendingPathComponent("commands-macos.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let commands = [
            CustomCommand(name: " Work ", title: " 工作 ", directory: " ~/Documents ", target: " pwd ", arguments: " {args} ", terminal: .iTerm2),
            CustomCommand(name: "editor", title: "编辑器", type: .program, directory: "/tmp", target: "/usr/bin/open", arguments: "-a TextEdit {args}", terminal: .none),
            CustomCommand(name: "search", title: "搜索", type: .url, directory: "", target: "https://example.com/?q={query}", terminal: .none)
        ]
        try await store.save(commands, reservedNames: [])
        let restored = try await CustomCommandStore(directory: directory).load(reservedNames: [])
        XCTAssertEqual(restored, try commands.map { try $0.validated(reservedNames: []) })
        XCTAssertEqual(restored[0].id, "work")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual((json["commands"] as? [[String: Any]])?.count, 3)
    }

    func testSaveRequiresSuccessfulLoad() async throws {
        let directory = try temporaryDirectory()
        let store = CustomCommandStore(directory: directory)
        await assertSaveFails(store, commands: [command()])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("commands-macos.json").path))
    }

    func testCorruptAndUnsupportedFilesRemainUntouchedAndBlockSave() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("commands-macos.json")
        for contents in ["broken json", "{\"schemaVersion\":2,\"commands\":[]}", "{\"commands\":[]}"] {
            let bytes = Data(contents.utf8)
            try bytes.write(to: url)
            let store = CustomCommandStore(directory: directory)
            await assertLoadFails(store)
            await assertSaveFails(store, commands: [command()])
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testFailedReloadBlocksPreviouslyLoadedStoreUntilSuccessfulReload() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("commands-macos.json")
        let store = CustomCommandStore(directory: directory)
        _ = try await store.load(reservedNames: [])
        try await store.save([command()], reservedNames: [])
        let original = try Data(contentsOf: url)
        try Data("corrupt".utf8).write(to: url)
        await assertLoadFails(store)
        try original.write(to: url)
        await assertSaveFails(store, commands: [])
        XCTAssertEqual(try Data(contentsOf: url), original)
        _ = try await store.load(reservedNames: [])
        try await store.save([], reservedNames: [])
        let commands = try await store.load(reservedNames: [])
        XCTAssertEqual(commands, [])
    }

    func testReadFailureBlocksSavingWithoutReplacingNonregularFile() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("commands-macos.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let store = CustomCommandStore(directory: directory)
        await assertLoadFails(store)
        await assertSaveFails(store, commands: [command()])
        XCTAssertTrue(try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }

    func testExternalChangeConflictsAndRequiresExplicitReload() async throws {
        let directory = try temporaryDirectory()
        let first = CustomCommandStore(directory: directory)
        let second = CustomCommandStore(directory: directory)
        _ = try await first.load(reservedNames: [])
        try await first.save([command()], reservedNames: [])
        _ = try await second.load(reservedNames: [])
        try await second.save([command("external")], reservedNames: [])
        let url = directory.appendingPathComponent("commands-macos.json")
        let external = try Data(contentsOf: url)
        do {
            try await first.save([], reservedNames: [])
            XCTFail("外部修改必须阻止保存")
        } catch {
            XCTAssertEqual(error as? CustomCommandError, .externalChange)
        }
        await assertSaveFails(first, commands: [])
        XCTAssertEqual(try Data(contentsOf: url), external)
        let reloaded = try await first.load(reservedNames: [])
        XCTAssertEqual(reloaded.map(\.name), ["external"])
        try await first.save([], reservedNames: [])
    }

    func testExternalCreationAndDeletionBothConflict() async throws {
        let directory = try temporaryDirectory()
        let first = CustomCommandStore(directory: directory)
        let second = CustomCommandStore(directory: directory)
        _ = try await first.load(reservedNames: [])
        _ = try await second.load(reservedNames: [])
        try await second.save([command()], reservedNames: [])
        await assertSaveFails(first, commands: [])
        let url = directory.appendingPathComponent("commands-macos.json")
        _ = try await first.load(reservedNames: [])
        try FileManager.default.removeItem(at: url)
        await assertSaveFails(first, commands: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNameValidationAndNormalization() throws {
        let valid = try command(" My-command_2 ").validated(reservedNames: [])
        XCTAssertEqual(valid.name, "my-command_2")
        for name in ["", "2abc", "a b", ":abc", "a/b", "中文", "x\ny"] {
            XCTAssertThrowsError(try command(name).validated(reservedNames: []), name)
        }
        XCTAssertThrowsError(try command(" HeLP ").validated(reservedNames: ["HELP"]))
    }

    func testValidationRejectsInvalidFieldsAndAllowsURLQueryTemplate() throws {
        var draft = command()
        for field in [\CustomCommand.name, \.title, \.directory, \.target, \.arguments] {
            var invalid = draft
            invalid[keyPath: field] += "\0"
            XCTAssertThrowsError(try invalid.validated(reservedNames: []))
        }
        draft.title = " "
        XCTAssertThrowsError(try draft.validated(reservedNames: []))
        draft = command()
        draft.target = " "
        XCTAssertThrowsError(try draft.validated(reservedNames: []))
        draft = command()
        draft.directory = "relative/path"
        XCTAssertThrowsError(try draft.validated(reservedNames: []))
        draft = command()
        draft.terminal = .none
        XCTAssertThrowsError(try draft.validated(reservedNames: []))
        draft.type = .program
        XCTAssertThrowsError(try draft.validated(reservedNames: []))
        draft.target = "~/bin/tool"
        XCTAssertNoThrow(try draft.validated(reservedNames: []))
        draft.type = .url
        draft.directory = ""
        for target in ["https://example.com/search?q={query}", "http://localhost:8000/{query}"] {
            draft.target = target
            XCTAssertNoThrow(try draft.validated(reservedNames: []))
        }
        for target in ["javascript:alert(1)", "file:///tmp/test", "ftp://example.com", "https://", "https://bad host/a"] {
            draft.target = target
            XCTAssertThrowsError(try draft.validated(reservedNames: []), target)
        }
    }

    func testDuplicateCollectionAndReservedNamesNeverReachDisk() async throws {
        let directory = try temporaryDirectory()
        let store = CustomCommandStore(directory: directory)
        _ = try await store.load(reservedNames: [])
        try await store.save([command()], reservedNames: [])
        let url = directory.appendingPathComponent("commands-macos.json")
        let original = try Data(contentsOf: url)
        await assertSaveFails(store, commands: [command("Work"), command(" WORK ")])
        do {
            try await store.save([command("help")], reservedNames: ["HELP"])
            XCTFail("保留名称不能保存")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), original)
        let duplicateJSON: [String: Any] = ["schemaVersion": 1, "commands": try [command("Work"), command("WORK")].map {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
        }]
        let duplicateBytes = try JSONSerialization.data(withJSONObject: duplicateJSON)
        try duplicateBytes.write(to: url)
        await assertLoadFails(store)
        await assertSaveFails(store, commands: [])
        XCTAssertEqual(try Data(contentsOf: url), duplicateBytes)
    }
}
