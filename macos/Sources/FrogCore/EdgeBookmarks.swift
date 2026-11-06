import Foundation

public struct EdgeBookmarkEntry: Equatable, Sendable {
    public var title: String
    public var url: String
    public var createdAt: Double
}

public struct EdgeFolder: Equatable, Sendable {
    public var name: String
    public var bookmarks: [EdgeBookmarkEntry]
}

public struct EdgeImportPayload: Equatable, Sendable {
    public var folders: [EdgeFolder]
    public var profiles: Int
    public var unsupported: Int

    public init(folders: [EdgeFolder] = [], profiles: Int = 0, unsupported: Int = 0) {
        self.folders = folders
        self.profiles = profiles
        self.unsupported = unsupported
    }
}

public struct EdgeImportSummary: Equatable, Sendable {
    public var profiles = 0
    public var groups = 0
    public var inserted = 0
    public var duplicates = 0
    public var unsupported = 0

    public init() {}
}

public enum EdgeBookmarks {
    public static let maximumBytes = 32 * 1024 * 1024
    static let chromiumEpochMicroseconds: Double = 11_644_473_600_000_000

    public static var defaultDataRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Microsoft Edge", isDirectory: true)
    }

    public static func load(from root: URL) throws -> EdgeImportPayload {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw BookmarkError.unavailable("未找到 Edge 数据目录：\(root.path)。请确认已安装 Microsoft Edge。")
        }

        var sources: [(file: URL, profile: String?)] = []
        if isDirectory.boolValue {
            let direct = root.appendingPathComponent("Bookmarks")
            if manager.fileExists(atPath: direct.path) {
                sources = [(direct, nil)]
            } else {
                let entries = try manager.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                let profiles = entries.filter { url in
                    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                          values.isDirectory == true else { return false }
                    let name = url.lastPathComponent
                    guard name != "Guest Profile", name != "System Profile" else { return false }
                    return manager.fileExists(atPath: url.appendingPathComponent("Bookmarks").path)
                }.sorted { lhs, rhs in
                    if (lhs.lastPathComponent == "Default") != (rhs.lastPathComponent == "Default") {
                        return lhs.lastPathComponent == "Default"
                    }
                    return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
                }
                sources = profiles.map { ($0.appendingPathComponent("Bookmarks"), $0.lastPathComponent) }
            }
        } else {
            sources = [(root, nil)]
        }

        guard !sources.isEmpty else {
            throw BookmarkError.unavailable("Edge 数据目录里没有找到 Bookmarks 文件：\(root.path)")
        }

        var folders: [EdgeFolder] = []
        var unsupported = 0
        let labelled = sources.count > 1
        for source in sources {
            let values = try source.file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                throw BookmarkError.invalidData("Edge 书签数据必须是普通文件：\(source.file.path)")
            }
            guard (values.fileSize ?? 0) <= maximumBytes else {
                throw BookmarkError.invalidData("Edge 书签文件超过 32 MB：\(source.file.path)")
            }
            let data: Data
            do { data = try Data(contentsOf: source.file) }
            catch { throw BookmarkError.unavailable("无法读取 Edge 书签文件：\(source.file.path)") }
            let parsed: EdgeImportPayload
            do { parsed = try parse(data: data, label: labelled ? source.profile : nil) }
            catch { throw BookmarkError.invalidData("无法导入 \(source.file.path)：\(error.localizedDescription)") }
            folders.append(contentsOf: parsed.folders)
            unsupported += parsed.unsupported
        }

        return EdgeImportPayload(folders: folders, profiles: sources.count, unsupported: unsupported)
    }

    public static func parse(data: Data, label: String? = nil) throws -> EdgeImportPayload {
        guard data.count <= maximumBytes else {
            throw BookmarkError.invalidData("Edge 书签文件超过 32 MB，无法导入。")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = object["roots"] as? [String: Any] else {
            throw BookmarkError.invalidData("无法识别 Edge 书签文件结构，文件可能已损坏。")
        }

        var accumulator = Accumulator()
        for (key, fallback) in [("bookmark_bar", "收藏夹栏"), ("other", "其他收藏夹")] {
            guard let value = roots[key] else { continue }
            guard let root = value as? [String: Any], root["type"] as? String == "folder" else {
                throw BookmarkError.invalidData("Edge 收藏夹根节点无效，未导入任何内容。")
            }
            let name = cleaned(root["name"] as? String) ?? fallback
            var rawPath = [name]
            if let label { rawPath[0] = "[\(label)] \(rawPath[0])" }
            try walk(children: root["children"], rawPath: rawPath, into: &accumulator)
        }

        guard !accumulator.folders.isEmpty else {
            throw BookmarkError.invalidData("Edge 文件缺少收藏夹栏和其他收藏夹，无法导入。")
        }
        return EdgeImportPayload(folders: accumulator.folders, profiles: 1, unsupported: accumulator.unsupported)
    }

    private static func walk(children: Any?, rawPath: [String], into accumulator: inout Accumulator) throws {
        guard let rows = children as? [[String: Any]] else {
            throw BookmarkError.invalidData("Edge 文件夹内容损坏，未导入任何内容。")
        }
        let folderName = limited(rawPath.joined(separator: " / "))
        accumulator.ensure(folderName)
        for row in rows {
            if row["type"] as? String == "folder" {
                let name = cleaned(row["name"] as? String) ?? "未命名文件夹"
                try walk(children: row["children"], rawPath: rawPath + [name], into: &accumulator)
                continue
            }
            guard row["type"] as? String == "url", let rawURL = row["url"] as? String else {
                throw BookmarkError.invalidData("Edge 书签节点无效，未导入任何内容。")
            }
            let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard BookmarkURL.isValid(url) else {
                accumulator.unsupported += 1
                continue
            }
            let title = cleaned(row["name"] as? String) ?? url
            accumulator.add(EdgeBookmarkEntry(
                title: limited(title),
                url: url,
                createdAt: timestamp(row["date_added"] ?? row["date_modified"])
            ), to: folderName)
        }
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func limited(_ value: String) -> String {
        guard value.count > 120 else { return value }
        return "…" + String(value.suffix(119))
    }

    private static func timestamp(_ raw: Any?) -> Double {
        let micros: Int64?
        if let text = raw as? String { micros = Int64(text) }
        else if let number = raw as? NSNumber { micros = number.int64Value }
        else { micros = nil }
        let now = Date().timeIntervalSince1970 * 1_000
        guard let micros, micros > 0 else { return now }
        let millis = (Double(micros) - chromiumEpochMicroseconds) / 1_000
        return millis.isFinite && millis >= 0 ? millis : now
    }

    private struct Accumulator {
        var folders: [EdgeFolder] = []
        var index: [String: Int] = [:]
        var unsupported = 0

        mutating func ensure(_ name: String) {
            guard index[name] == nil else { return }
            index[name] = folders.count
            folders.append(EdgeFolder(name: name, bookmarks: []))
        }

        mutating func add(_ bookmark: EdgeBookmarkEntry, to name: String) {
            ensure(name)
            folders[index[name]!].bookmarks.append(bookmark)
        }
    }
}

extension BookmarkDocument {
    public mutating func importEdge(_ payload: EdgeImportPayload) throws -> EdgeImportSummary {
        var summary = EdgeImportSummary()
        summary.profiles = payload.profiles
        summary.unsupported = payload.unsupported

        var urls = Set(bookmarks.map(\.url))
        var groupIDs: [String: String] = [:]
        for group in groups { groupIDs[group.name] = group.id }
        let maxRootOrder = max(groups.lazy.map(\.order).max() ?? -1,
                               bookmarks.lazy.filter { $0.groupId == nil }.map(\.order).max() ?? -1)
        let nextRootOrder: Int
        if maxRootOrder >= Int.max - payload.folders.count {
            let ids = rootItems.map(\.id)
            try reorderRoot(ids: ids)
            nextRootOrder = ids.count
        } else {
            nextRootOrder = maxRootOrder + 1
        }
        var rootOrder = nextRootOrder
        let incomingCount = payload.folders.reduce(0) { $0 + $1.bookmarks.count }
        let crowdedGroups = Set(bookmarks.lazy.filter { $0.order >= Int.max - incomingCount }.compactMap(\.groupId))
        for id in crowdedGroups {
            try reorderGroup(id: id, bookmarkIDs: bookmarks(in: id).map(\.id))
        }
        var nextOrders: [String: Int] = [:]
        for bookmark in bookmarks {
            guard let id = bookmark.groupId else { continue }
            nextOrders[id] = max(nextOrders[id] ?? 0, bookmark.order + 1)
        }

        for folder in payload.folders {
            let name = EdgeBookmarks.limited(folder.name.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !name.isEmpty else { continue }
            let groupID: String
            if let existing = groupIDs[name] {
                groupID = existing
            } else {
                let group = BookmarkGroup(name: name, order: rootOrder)
                rootOrder += 1
                groups.append(group)
                groupIDs[name] = group.id
                summary.groups += 1
                groupID = group.id
            }
            for entry in folder.bookmarks {
                let url = entry.url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard BookmarkURL.isValid(url) else {
                    summary.unsupported += 1
                    continue
                }
                guard urls.insert(url).inserted else {
                    summary.duplicates += 1
                    continue
                }
                let order = nextOrders[groupID] ?? 0
                nextOrders[groupID] = order + 1
                let cleanedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = EdgeBookmarks.limited(cleanedTitle.isEmpty ? url : cleanedTitle)
                let createdAt = entry.createdAt.isFinite && entry.createdAt >= 0
                    ? entry.createdAt : Date().timeIntervalSince1970 * 1_000
                bookmarks.append(Bookmark(
                    title: title, url: url, groupId: groupID,
                    order: order, createdAt: createdAt
                ))
                summary.inserted += 1
            }
        }

        self = try validated()
        return summary
    }
}
