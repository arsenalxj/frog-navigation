import XCTest
import Combine
import Darwin
@testable import FrogCore

final class BookmarkStoreTests: XCTestCase {
    private var scratch: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("FrogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        suite = "FrogTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: scratch)
    }
    private func file(_ directory: URL) -> URL { directory.appendingPathComponent("bookmarks.json") }
    private func fixture(_ title: String = "原数据") -> BookmarkDocument {
        BookmarkDocument(bookmarks: [Bookmark(title: title, url: "https://example.com")])
    }
    private func folder(_ name: String) throws -> URL {
        let directory = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    func testFirstLaunchCreatesEmptyButConfiguredMissingFileIsPreserved() async throws {
        let directory = scratch.appendingPathComponent("first", isDirectory: true)
        let store = BookmarkStore(directoryOverride: directory, defaults: defaults)
        await store.load()
        XCTAssertTrue(store.isLoaded)
        XCTAssertEqual(try BookmarkDocument.decode(Data(contentsOf: file(directory))), BookmarkDocument())
        try FileManager.default.removeItem(at: file(directory))
        let reopened = BookmarkStore(defaults: defaults)
        await reopened.load()
        XCTAssertFalse(reopened.isLoaded)
        XCTAssertEqual(reopened.directory.resolvingSymlinksInPath(), directory.resolvingSymlinksInPath())
        XCTAssertNotNil(reopened.issue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(directory).path))
    }

    @MainActor
    func testQueuedMutationsEachUseLastCommittedDocument() async throws {
        let store = BookmarkStore(directoryOverride: scratch, defaults: defaults)
        await store.load()
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            for number in 0..<16 {
                tasks.addTask { @MainActor in
                    try await store.apply { document in
                        _ = try document.upsertBookmark(title: "条目\(number)", url: "https://example.com/\(number)", groupID: nil)
                    }
                }
            }
            try await tasks.waitForAll()
        }
        XCTAssertEqual(store.document.bookmarks.count, 16)
        XCTAssertEqual(try BookmarkDocument.decode(Data(contentsOf: file(scratch))), store.document)
        XCTAssertFalse(store.isBusy)
    }

    @MainActor
    func testExternalChangeRejectsStaleSaveAndLoadsLatest() async throws {
        let initial = fixture()
        try initial.encoded().write(to: file(scratch))
        let store = BookmarkStore(directoryOverride: scratch, defaults: defaults)
        await store.load()
        let external = fixture("外部修改")
        try external.encoded().write(to: file(scratch), options: .atomic)
        do {
            try await store.apply { $0.bookmarks[0].title = "过时的修改" }
            XCTFail("外部更新后的旧快照不得覆盖主文件")
        } catch { XCTAssertEqual(error as? BookmarkError, .conflict) }
        XCTAssertEqual(store.document, external)
        XCTAssertEqual(try BookmarkDocument.decode(Data(contentsOf: file(scratch))), external)
        try await store.apply { $0.bookmarks[0].title = "重试成功" }
        XCTAssertEqual(store.document.bookmarks.first?.title, "重试成功")
    }

    @MainActor
    func testCorruptAndMissingExternalFilesPauseWritesAndKeepLoadedData() async throws {
        let initial = fixture()
        try initial.encoded().write(to: file(scratch))
        let store = BookmarkStore(directoryOverride: scratch, defaults: defaults)
        await store.load()
        for broken: Data? in [Data("broken".utf8), nil] {
            if let broken { try broken.write(to: file(scratch)) }
            else { try FileManager.default.removeItem(at: file(scratch)) }
            await store.reloadIfChanged()
            XCTAssertEqual(store.document, initial)
            do { try await store.apply { $0.bookmarks.removeAll() }; XCTFail("不可覆盖损坏或缺失文件") }
            catch { XCTAssertNotNil(store.issue) }
            if let broken { XCTAssertEqual(try Data(contentsOf: file(scratch)), broken) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: file(scratch).path)) }
        }
        try initial.encoded().write(to: file(scratch))
        await store.reloadIfChanged()
        try await store.apply { $0.bookmarks.removeAll() }
        XCTAssertTrue(store.document.bookmarks.isEmpty)
    }

    @MainActor
    func testWriteFailureRollsBackAndCleansTemporaryFiles() async throws {
        if getuid() == 0 { throw XCTSkip("root 可以绕过目录权限，无法测试权限失败。") }
        let initial = fixture()
        try initial.encoded().write(to: file(scratch))
        let store = BookmarkStore(directoryOverride: scratch, defaults: defaults)
        await store.load()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: scratch.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path) }
        do { try await store.apply { $0.bookmarks.removeAll() }; XCTFail("只读目录不得保存成功") }
        catch { XCTAssertNotNil(store.issue) }
        XCTAssertEqual(store.document, initial)
        XCTAssertEqual(try BookmarkDocument.decode(Data(contentsOf: file(scratch))), initial)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), ["bookmarks.json"])
    }

    @MainActor
    func testOversizedSavePreservesFileAndLoadedDataAndCanReload() async throws {
        let initial = fixture()
        let originalBytes = try initial.encoded()
        try originalBytes.write(to: file(scratch))
        let store = BookmarkStore(directoryOverride: scratch, defaults: defaults)
        await store.load()
        let oversizedURL = "https://example.com/" + String(repeating: "a", count: 32 * 1_024 * 1_024)
        do {
            try await store.apply { $0.bookmarks[0].url = oversizedURL }
            XCTFail("编码超过 32 MB 的数据必须在覆盖主文件前拒绝")
            return
        } catch {
            XCTAssertEqual(error as? BookmarkError, .invalidData("书签数据超过 32 MB，无法保存。请减少数据量后重试；原文件保持不变。"))
        }
        XCTAssertEqual(try Data(contentsOf: file(scratch)), originalBytes)
        XCTAssertTrue(store.document == initial, "超限保存失败后已加载数据应保持不变")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), ["bookmarks.json"])
        await store.reloadIfChanged()
        XCTAssertNil(store.issue)
        XCTAssertTrue(store.document == initial, "超限保存失败后应能重新载入原数据")
        try await store.apply { $0.bookmarks[0].title = "重试保存成功" }
        XCTAssertEqual(try BookmarkDocument.decode(Data(contentsOf: file(scratch))).bookmarks[0].title, "重试保存成功")
    }

    @MainActor
    func testSwitchExistingOrEmptyDirectoryAndKeepOriginalOnInvalid() async throws {
        let initialDirectory = try folder("initial")
        let initial = fixture()
        try initial.encoded().write(to: file(initialDirectory))
        let store = BookmarkStore(directoryOverride: initialDirectory, defaults: defaults)
        await store.load()
        let emptyDirectory = try folder("empty")
        try await store.switchDirectory(emptyDirectory)
        XCTAssertEqual(store.document, initial)
        XCTAssertEqual(try BookmarkDocument.decode(Data(contentsOf: file(emptyDirectory))), initial)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file(initialDirectory).path))
        let existingDirectory = try folder("existing")
        let existing = fixture("目标目录数据")
        let existingBytes = try existing.encoded()
        try existingBytes.write(to: file(existingDirectory))
        try await store.switchDirectory(existingDirectory)
        XCTAssertEqual(store.document, existing)
        XCTAssertEqual(try Data(contentsOf: file(existingDirectory)), existingBytes)
        let badDirectory = try folder("invalid")
        try Data("invalid".utf8).write(to: file(badDirectory))
        do { try await store.switchDirectory(badDirectory); XCTFail("损坏目标不可切换") } catch {}
        XCTAssertEqual(store.directory, existingDirectory)
        XCTAssertEqual(store.document, existing)
        XCTAssertEqual(defaults.string(forKey: BookmarkStore.directoryPreferenceKey), existingDirectory.path)
    }

    @MainActor
    func testExportIncludesArrivedExternalChangesAndCannotOverwriteMain() async throws {
        let store = BookmarkStore(directoryOverride: scratch, defaults: defaults)
        await store.load()
        let updated = fixture("备份前外部更新")
        try updated.encoded().write(to: file(scratch), options: .atomic)
        let backup = scratch.appendingPathComponent("backup.json")
        try await store.exportBackup(to: backup)
        XCTAssertEqual(try BookmarkDocument.decode(Data(contentsOf: backup)), updated)
        XCTAssertEqual(store.document, updated)
        XCTAssertEqual(store.directory, scratch)
        do { try await store.exportBackup(to: file(scratch)); XCTFail("不能将主文件作为备份目标") }
        catch { XCTAssertEqual(error as? BookmarkError, .sameBackupLocation) }
    }

    @MainActor
    func testRestorePreservesIDsDuplicateURLsEmptyGroupsAndEmptyDataset() async throws {
        let store = BookmarkStore(directoryOverride: scratch, defaults: defaults)
        await store.load()
        let bookmark = Bookmark(title: "同名", url: "https://example.com", order: 900)
        let replacement = BookmarkDocument(groups: [BookmarkGroup(name: "空文件夹", order: 77)], bookmarks: [
            bookmark, Bookmark(title: bookmark.title, url: bookmark.url, order: 900)
        ])
        let backup = scratch.appendingPathComponent("restore.json")
        let bytes = try replacement.encoded()
        try bytes.write(to: backup)
        try Data("损坏主文件也允许明确恢复".utf8).write(to: file(scratch))
        try await store.restoreBackup(from: backup)
        XCTAssertEqual(store.document, replacement)
        XCTAssertEqual(try Data(contentsOf: file(scratch)), bytes)
        XCTAssertEqual(store.directory, scratch)
        try Data("bad".utf8).write(to: backup)
        do { try await store.restoreBackup(from: backup); XCTFail("无效备份不可覆盖") } catch {}
        XCTAssertEqual(store.document, replacement)
        XCTAssertEqual(try Data(contentsOf: file(scratch)), bytes)
        try BookmarkDocument().encoded().write(to: backup)
        try await store.restoreBackup(from: backup)
        XCTAssertEqual(store.document, BookmarkDocument())
        XCTAssertEqual(try BookmarkDocument.decode(Data(contentsOf: file(scratch))), BookmarkDocument())
    }

    @MainActor
    func testFailedExportStillPublishesExternalSnapshotBeforeAnotherSave() async throws {
        try fixture().encoded().write(to: file(scratch))
        let store = BookmarkStore(directoryOverride: scratch, defaults: defaults)
        await store.load()
        let external = fixture("最新数据")
        try external.encoded().write(to: file(scratch), options: .atomic)
        let invalidDestination = scratch.appendingPathComponent("不存在/backup.json")
        do { try await store.exportBackup(to: invalidDestination); XCTFail("不存在的目录应备份失败") } catch {}
        XCTAssertEqual(store.document, external)
        try await store.apply { $0.bookmarks[0].title = "基于最新数据修改" }
        XCTAssertEqual(store.document.bookmarks[0].id, external.bookmarks[0].id)
        XCTAssertEqual(try BookmarkDocument.decode(Data(contentsOf: file(scratch))).bookmarks[0].id, external.bookmarks[0].id)
    }

    @MainActor
    func testRestoreWriteFailurePreservesCurrentFileAndLoadedState() async throws {
        if getuid() == 0 { throw XCTSkip("root 可以绕过目录权限。") }
        let directory = try folder("readonly")
        let initial = fixture("保留数据")
        let bytes = try initial.encoded()
        try bytes.write(to: file(directory))
        let store = BookmarkStore(directoryOverride: directory, defaults: defaults)
        await store.load()
        let backup = scratch.appendingPathComponent("source.json")
        try BookmarkDocument().encoded().write(to: backup)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        do { try await store.restoreBackup(from: backup); XCTFail("只读目录不能恢复成功") } catch {}
        XCTAssertEqual(store.document, initial)
        XCTAssertEqual(try Data(contentsOf: file(directory)), bytes)
    }

    @MainActor
    func testWatcherReadsSameSizeInPlaceUpdateWithoutWritingBack() async throws {
        var initial = fixture("AAA")
        try initial.encoded().write(to: file(scratch))
        let store = BookmarkStore(directoryOverride: scratch, defaults: defaults)
        await store.load()
        try await Task.sleep(nanoseconds: 250_000_000)
        let updated = expectation(description: "同长度原地修改刷新")
        let subscription = store.$document.sink { if $0.bookmarks.first?.title == "BBB" { updated.fulfill() } }
        defer { subscription.cancel() }
        initial.bookmarks[0].title = "BBB"
        let bytes = try initial.encoded()
        let handle = try FileHandle(forWritingTo: file(scratch))
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
        try handle.close()
        let modified = try file(scratch).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        await fulfillment(of: [updated], timeout: 3)
        XCTAssertEqual(try Data(contentsOf: file(scratch)), bytes)
        XCTAssertEqual(try file(scratch).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
    }

    @MainActor
    func testWatcherRecoversAfterDirectoryReplacement() async throws {
        let directory = try folder("watched")
        let store = BookmarkStore(directoryOverride: directory, defaults: defaults)
        await store.load()
        try await Task.sleep(nanoseconds: 250_000_000)
        try FileManager.default.removeItem(at: directory)
        try await Task.sleep(nanoseconds: 350_000_000)
        let updated = expectation(description: "目录重建后刷新")
        let subscription = store.$document.sink { if $0.bookmarks.first?.title == "重建" { updated.fulfill() } }
        defer { subscription.cancel() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try fixture("重建").encoded().write(to: file(directory))
        await fulfillment(of: [updated], timeout: 3)
        XCTAssertEqual(store.document.bookmarks.first?.title, "重建")
    }
}
