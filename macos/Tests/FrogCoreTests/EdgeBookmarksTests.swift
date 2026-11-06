import XCTest
@testable import FrogCore

final class EdgeBookmarksTests: XCTestCase {
    private func folder(_ name: String, _ children: [[String: Any]]) -> [String: Any] {
        ["type": "folder", "name": name, "children": children]
    }

    private func url(_ name: String, _ value: String, added: String = "0") -> [String: Any] {
        ["type": "url", "name": name, "url": value, "date_added": added]
    }

    private func data(bar: [String: Any], other: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "version": 1,
            "roots": ["bookmark_bar": bar, "other": other, "synced": ["type": "folder", "name": "已同步", "children": []]]
        ])
    }

    func testParseFlattensNestedFoldersAndFiltersUnsupported() throws {
        let payload = try EdgeBookmarks.parse(data: data(
            bar: ["type": "folder", "name": "收藏夹栏", "children": [
                url("根级", "https://root.test/", added: "13152724350000000"),
                url("", "https://untitled.test/"),
                folder("开发", [
                    url("B", "https://b.test/"),
                    url("B 重复", "https://b.test/"),
                    folder("工具", [url("C", "https://c.test/")]),
                    folder("空文件夹", [])
                ]),
                url("脚本", "javascript:alert(1)")
            ]],
            other: ["type": "folder", "name": "其他收藏夹", "children": [url("D", "https://d.test/")]]
        ))

        XCTAssertEqual(payload.unsupported, 1)
        XCTAssertEqual(payload.folders.map(\.name), [
            "收藏夹栏", "收藏夹栏 / 开发", "收藏夹栏 / 开发 / 工具", "收藏夹栏 / 开发 / 空文件夹", "其他收藏夹"
        ])
        XCTAssertEqual(payload.folders[0].bookmarks.map(\.url), ["https://root.test/", "https://untitled.test/"])
        XCTAssertEqual(payload.folders[0].bookmarks[0].createdAt, 1_508_250_750_000)
        XCTAssertEqual(payload.folders[0].bookmarks[1].title, "https://untitled.test/")
        XCTAssertEqual(payload.folders[1].bookmarks.map(\.url), ["https://b.test/", "https://b.test/"])
        XCTAssertTrue(payload.folders[3].bookmarks.isEmpty)
        XCTAssertEqual(payload.folders[4].bookmarks.map(\.url), ["https://d.test/"])
    }

    func testParseLabelsProfilesAndRejectsCorruptFiles() throws {
        let payload = try EdgeBookmarks.parse(data: data(
            bar: ["type": "folder", "name": "收藏夹栏", "children": [url("A", "https://a.test/")]],
            other: ["type": "folder", "name": "其他收藏夹", "children": []]
        ), label: "Profile 1")
        XCTAssertEqual(payload.folders.first?.name, "[Profile 1] 收藏夹栏")

        XCTAssertThrowsError(try EdgeBookmarks.parse(data: Data("{\"roots\":{}}".utf8)))
        XCTAssertThrowsError(try EdgeBookmarks.parse(data: Data("{broken".utf8)))
    }

    func testImportMergesByNameAndDeduplicatesGlobally() throws {
        var document = BookmarkDocument()
        let folder = try document.addGroup(name: "收藏夹栏")
        try document.upsertBookmark(title: "旧 A", url: "https://a.test/", groupID: folder)
        try document.upsertBookmark(title: "根 D", url: "https://d.test/", groupID: nil)

        let payload = EdgeImportPayload(folders: [
            EdgeFolder(name: "收藏夹栏", bookmarks: [
                .init(title: "A", url: "https://a.test/", createdAt: 1),
                .init(title: "B", url: "https://b.test/", createdAt: 2)
            ]),
            EdgeFolder(name: "其他收藏夹", bookmarks: [
                .init(title: "D", url: "https://d.test/", createdAt: 3),
                .init(title: "E", url: "https://e.test/", createdAt: 4)
            ]),
            EdgeFolder(name: "收藏夹栏 / 开发", bookmarks: [
                .init(title: "F", url: "https://f.test/", createdAt: 5),
                .init(title: "F 重复", url: "https://f.test/", createdAt: 6)
            ]),
            EdgeFolder(name: "空文件夹", bookmarks: [])
        ], profiles: 2, unsupported: 3)

        let first = try document.importEdge(payload)
        XCTAssertEqual(first.inserted, 3)
        XCTAssertEqual(first.duplicates, 3)
        XCTAssertEqual(first.groups, 3)
        XCTAssertEqual(first.profiles, 2)
        XCTAssertEqual(first.unsupported, 3)
        XCTAssertEqual(document.bookmarks(in: folder).map(\.url), ["https://a.test/", "https://b.test/"])
        XCTAssertEqual(document.groups.first { $0.name == "其他收藏夹" }?.name, "其他收藏夹")
        XCTAssertEqual(document.groups.first { $0.name == "空文件夹" }?.name, "空文件夹")
        XCTAssertEqual(Set(document.bookmarks.map(\.url)).count, document.bookmarks.count)
        XCTAssertEqual(document.bookmarks(in: nil).map(\.url), ["https://d.test/"])

        let second = try document.importEdge(payload)
        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.duplicates, 6)
        XCTAssertEqual(second.groups, 0)
    }

    func testImportTruncatesLongNamesAndKeepsOrderWithinGroup() throws {
        let longName = String(repeating: "很长的文件夹", count: 30)
        var document = BookmarkDocument()
        let payload = EdgeImportPayload(folders: [
            EdgeFolder(name: "超长", bookmarks: [
                .init(title: String(repeating: "标题", count: 100), url: "https://a.test/", createdAt: 1),
                .init(title: "B", url: "https://b.test/", createdAt: 2)
            ]),
            EdgeFolder(name: longName, bookmarks: [])
        ])
        _ = try document.importEdge(payload)
        let longGroup = try XCTUnwrap(document.groups.first { $0.name.count > 1 && $0.name.hasPrefix("…") })
        XCTAssertLessThanOrEqual(longGroup.name.count, 120)
        let longBookmark = try XCTUnwrap(document.bookmarks.first { $0.url == "https://a.test/" })
        XCTAssertLessThanOrEqual(longBookmark.title.count, 120)
        XCTAssertEqual(document.bookmarks(in: longBookmark.groupId).map(\.url), ["https://a.test/", "https://b.test/"])
    }

    func testLoadScansProfilesAndLabelsThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Frog-Edge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for profile in ["Default", "Profile 1", "Guest Profile"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(profile), withIntermediateDirectories: true)
        }
        let bytes = data(
            bar: ["type": "folder", "name": "收藏夹栏", "children": [url("A", "https://a.test/")]],
            other: ["type": "folder", "name": "其他收藏夹", "children": []]
        )
        try bytes.write(to: root.appendingPathComponent("Default/Bookmarks"))
        try bytes.write(to: root.appendingPathComponent("Profile 1/Bookmarks"))
        try bytes.write(to: root.appendingPathComponent("Guest Profile/Bookmarks"))

        let payload = try EdgeBookmarks.load(from: root)
        XCTAssertEqual(payload.profiles, 2)
        XCTAssertEqual(payload.folders.filter { !$0.bookmarks.isEmpty }.map(\.name), [
            "[Default] 收藏夹栏", "[Profile 1] 收藏夹栏"
        ])

        let single = root.appendingPathComponent("Default")
        XCTAssertEqual(try EdgeBookmarks.load(from: single).folders.first?.name, "收藏夹栏")
        XCTAssertThrowsError(try EdgeBookmarks.load(from: root.appendingPathComponent("missing")))
    }

    func testEmptyProfileDoesNotBlockOtherProfiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Frog-Edge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for profile in ["Default", "Profile 1"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(profile), withIntermediateDirectories: true)
        }
        try data(bar: folder("收藏夹栏", [folder("空目录", [])]), other: folder("其他收藏夹", []))
            .write(to: root.appendingPathComponent("Default/Bookmarks"))
        try data(bar: folder("收藏夹栏", [url("文档", "https://docs.test/")]), other: folder("其他收藏夹", []))
            .write(to: root.appendingPathComponent("Profile 1/Bookmarks"))
        let payload = try EdgeBookmarks.load(from: root)
        var document = BookmarkDocument()
        let summary = try document.importEdge(payload)
        XCTAssertEqual(summary.profiles, 2)
        XCTAssertEqual(document.bookmarks.map(\.url), ["https://docs.test/"])
        let emptyGroup = try XCTUnwrap(document.groups.first { $0.name == "[Default] 收藏夹栏 / 空目录" })
        XCTAssertEqual(document.bookmarks(in: emptyGroup.id), [])
    }

    func testUnsupportedOnlyProfileReportsSkippedEntries() throws {
        let payload = try EdgeBookmarks.parse(data: data(
            bar: folder("收藏夹栏", [url("本地", "file:///tmp/local.html"), url("脚本", "javascript:alert(1)")]),
            other: folder("其他收藏夹", [])
        ))
        var document = BookmarkDocument()
        let summary = try document.importEdge(payload)
        XCTAssertEqual(summary.unsupported, 2)
        XCTAssertEqual(summary.inserted, 0)
        XCTAssertEqual(document.bookmarks, [])
    }

    func testMalformedChildrenAreNotSilentlyDropped() throws {
        let valid = url("有效", "https://valid.test/")
        for malformed: [String: Any] in [
            ["type": "folder", "name": "坏目录", "children": "not an array"],
            ["type": "url", "name": "坏书签"],
            ["type": "unexpected", "name": "未知节点"]
        ] {
            XCTAssertThrowsError(try EdgeBookmarks.parse(data: data(
                bar: folder("收藏夹栏", [valid, malformed]), other: folder("其他收藏夹", [])
            )))
        }
    }

    func testImportAppendsAfterExtremeOrdersWithoutTies() throws {
        let group = BookmarkGroup(name: "收藏夹栏", order: Int.max - 1)
        let old = Bookmark(title: "旧书签", url: "https://old.test/", groupId: group.id, order: Int.max)
        var document = BookmarkDocument(groups: [group], bookmarks: [old])
        let payload = try EdgeBookmarks.parse(data: data(
            bar: folder("收藏夹栏", [url("A", "https://a.test/"), url("B", "https://b.test/"),
                                    folder("子目录", [])]),
            other: folder("其他收藏夹", [])
        ))
        _ = try document.importEdge(payload)
        let children = document.bookmarks(in: group.id)
        XCTAssertEqual(children.map(\.url), ["https://old.test/", "https://a.test/", "https://b.test/"])
        XCTAssertEqual(Set(children.map(\.order)).count, 3)
        XCTAssertEqual(document.rootItems.map(\.title), ["收藏夹栏", "收藏夹栏 / 子目录", "其他收藏夹"])
        XCTAssertEqual(Set(document.rootItems.map(\.order)).count, 3)
    }
}
