import XCTest
@testable import FrogCore

final class BookmarkDocumentTests: XCTestCase {
    func testFrogDocumentMatchesWindowsFixture() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("windows/tests/fixtures/macos-v1.json"))
        let document = try BookmarkDocument.decode(data)
        XCTAssertEqual(document.format, "frog-bookmarks")
        XCTAssertEqual(try BookmarkDocument.decode(document.encoded()), document)
        XCTAssertEqual(BookmarkDocument().format, document.format)
    }

    func testRootGroupingMovingAndSortingShareOneSequence() throws {
        var document = BookmarkDocument()
        let first = try document.upsertBookmark(title: "第一条", url: "example.com", groupID: nil)
        let folder = try document.addGroup(name: "工作")
        let last = try document.upsertBookmark(title: "第三条", url: "example.org", groupID: nil)
        XCTAssertEqual(document.rootItems.map(\.id), [first, folder, last])
        try document.reorderRoot(ids: [last, first, folder])
        try document.moveBookmark(id: first, to: folder)
        XCTAssertEqual(document.rootItems.map(\.id), [last, folder])
        XCTAssertEqual(document.bookmarks(in: folder).map(\.id), [first])
        XCTAssertThrowsError(try document.deleteGroup(id: folder))
        try document.moveBookmark(id: first, to: nil, before: last)
        try document.deleteGroup(id: folder)
        XCTAssertEqual(document.rootItems.map(\.id), [first, last])
    }

    func testMergeKeepsTargetLocationAndLeavesFormerGroup() throws {
        var document = BookmarkDocument()
        let previous = try document.addGroup(name: "旧文件夹")
        let source = try document.upsertBookmark(title: "来源", url: "https://a.test", groupID: previous)
        let target = try document.upsertBookmark(title: "目标", url: "https://b.test", groupID: nil)
        let merged = try document.mergeBookmarks(sourceID: source, targetID: target)
        XCTAssertEqual(document.rootItems.map(\.id), [previous, merged])
        XCTAssertEqual(document.bookmarks(in: merged).map(\.id), [target, source])
        XCTAssertTrue(document.bookmarks(in: previous).isEmpty)
        XCTAssertEqual(document.groups.first { $0.id == merged }?.name, "新建文件夹")
    }

    func testSchemaRequiresExplicitGroupFieldAndValidReferences() throws {
        let bookmark = Bookmark(title: "示例", url: "https://example.com")
        let valid = BookmarkDocument(bookmarks: [bookmark])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: valid.encoded()) as? [String: Any])
        var rows = try XCTUnwrap(json["bookmarks"] as? [[String: Any]])
        XCTAssertTrue(rows[0]["groupId"] is NSNull)
        rows[0].removeValue(forKey: "groupId")
        json["bookmarks"] = rows
        XCTAssertThrowsError(try BookmarkDocument.decode(JSONSerialization.data(withJSONObject: json)))
        var invalid = valid
        invalid.bookmarks[0].groupId = UUID().uuidString
        XCTAssertThrowsError(try invalid.validated())
        invalid = valid
        invalid.bookmarks.append(Bookmark(id: bookmark.id.lowercased(), title: "重复ID", url: bookmark.url))
        XCTAssertThrowsError(try invalid.validated())
        invalid = valid
        invalid.schemaVersion = 2
        XCTAssertThrowsError(try invalid.validated())
    }

    func testURLNormalizationSupportsPortsAndIPv6AndRejectsOtherSchemes() throws {
        XCTAssertEqual(try BookmarkURL.normalize(" example.com:8080/path "), "https://example.com:8080/path")
        XCTAssertEqual(try BookmarkURL.normalize("[::1]:8080/path"), "https://[::1]:8080/path")
        XCTAssertEqual(try BookmarkURL.normalize("localhost:8080"), "https://localhost:8080")
        for invalid in ["javascript:alert(1)", "file:///etc/hosts", "mailto:a@example.com", "ftp://example.com", "not a domain", "https://"] {
            XCTAssertThrowsError(try BookmarkURL.normalize(invalid), invalid)
        }
    }

    func testInvalidEditAndNewGroupRollbackTogether() throws {
        var document = BookmarkDocument()
        let old = document
        XCTAssertThrowsError(try document.upsertBookmark(id: UUID().uuidString, title: "标题", url: "example.com", groupID: nil, newGroupName: "文件夹"))
        XCTAssertEqual(document, old)
    }

    func testImportedExtremeOrderCanBeAppendedWithoutOverflow() throws {
        let existing = Bookmark(title: "旧条目", url: "https://example.com", order: Int.max)
        var document = BookmarkDocument(bookmarks: [existing])
        XCTAssertEqual(try BookmarkDocument.decode(document.encoded()).bookmarks[0].order, Int.max)
        let added = try document.upsertBookmark(title: "新条目", url: "https://example.org", groupID: nil)
        XCTAssertEqual(document.rootItems.map(\.id), [existing.id, added])
        XCTAssertEqual(document.rootItems.map(\.order), [0, 1])
        document.groups = [BookmarkGroup(name: "极端排序", order: Int.max)]
        _ = try document.addGroup(name: "可追加")
        XCTAssertEqual(document.rootItems.map(\.order), [0, 1, 2, 3])
    }

    func testSearchIncludesFolderContentsExactlyOnceInLogicalOrder() throws {
        var document = BookmarkDocument()
        let root = try document.upsertBookmark(title: "ROOT", url: "https://example.com/root", groupID: nil)
        let folder = try document.addGroup(name: "文件夹")
        let child = try document.upsertBookmark(title: "Child", url: "https://example.com/child", groupID: folder)
        XCTAssertEqual(document.search("EXAMPLE").map(\.id), [root, child])
        XCTAssertEqual(document.search("child").map(\.id), [child])
    }
}
