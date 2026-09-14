import Foundation

public struct Bookmark: Codable, Identifiable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey { case id, title, url, groupId, order, createdAt }
    public var id: String
    public var title: String
    public var url: String
    public var groupId: String?
    public var order: Int
    public var createdAt: Double

    public init(id: String = UUID().uuidString, title: String, url: String, groupId: String? = nil,
                order: Int = 0, createdAt: Double = Date().timeIntervalSince1970 * 1_000) {
        self.id = id; self.title = title; self.url = url
        self.groupId = groupId; self.order = order; self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(String.self, forKey: .url)
        guard container.contains(.groupId) else {
            throw DecodingError.keyNotFound(CodingKeys.groupId, .init(codingPath: decoder.codingPath, debugDescription: "缺少书签归属字段。"))
        }
        groupId = try container.decodeIfPresent(String.self, forKey: .groupId)
        order = try container.decode(Int.self, forKey: .order)
        createdAt = try container.decode(Double.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(url, forKey: .url)
        try container.encode(groupId, forKey: .groupId)
        try container.encode(order, forKey: .order)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

public struct BookmarkGroup: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var order: Int
    public init(id: String = UUID().uuidString, name: String, order: Int = 0) {
        self.id = id; self.name = name; self.order = order
    }
}

public enum RootItem: Equatable, Identifiable, Sendable {
    case bookmark(Bookmark)
    case group(BookmarkGroup)

    public var id: String {
        switch self { case .bookmark(let value): return value.id; case .group(let value): return value.id }
    }
    public var order: Int {
        switch self { case .bookmark(let value): return value.order; case .group(let value): return value.order }
    }
    public var title: String {
        switch self { case .bookmark(let value): return value.title; case .group(let value): return value.name }
    }
}

public struct BookmarkDocument: Codable, Equatable, Sendable {
    public var format: String
    public var schemaVersion: Int
    public var groups: [BookmarkGroup]
    public var bookmarks: [Bookmark]
    public init(format: String = "frog-bookmarks", schemaVersion: Int = 1,
                groups: [BookmarkGroup] = [], bookmarks: [Bookmark] = []) {
        self.format = format; self.schemaVersion = schemaVersion
        self.groups = groups; self.bookmarks = bookmarks
    }

    public var rootItems: [RootItem] {
        (groups.map(RootItem.group) + bookmarks.filter { $0.groupId == nil }.map(RootItem.bookmark))
            .sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
    }
    public func bookmarks(in groupID: String?) -> [Bookmark] {
        bookmarks.filter { $0.groupId == groupID }.sorted {
            $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order
        }
    }
    public func search(_ query: String) -> [Bookmark] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let ordered = rootItems.flatMap { item -> [Bookmark] in
            switch item {
            case .bookmark(let bookmark): return [bookmark]
            case .group(let group): return bookmarks(in: group.id)
            }
        }
        guard !query.isEmpty else { return ordered }
        return ordered.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query) }
    }

    public func validated() throws -> BookmarkDocument {
        guard format == "frog-bookmarks", schemaVersion == 1 else { throw BookmarkError.unsupportedFormat }
        var ids = Set<String>()
        for group in groups {
            guard let uuid = UUID(uuidString: group.id), ids.insert(uuid.uuidString).inserted else { throw BookmarkError.invalidData("文件夹 ID 无效或重复。") }
            guard !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  group.name.count <= 120, group.order >= 0 else { throw BookmarkError.invalidData("文件夹名称或排序无效。") }
        }
        let groupIDs = Set(groups.map(\.id))
        for bookmark in bookmarks {
            guard let uuid = UUID(uuidString: bookmark.id), ids.insert(uuid.uuidString).inserted else { throw BookmarkError.invalidData("书签 ID 无效或重复。") }
            guard !bookmark.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  bookmark.title.count <= 120, bookmark.order >= 0,
                  bookmark.createdAt.isFinite, bookmark.createdAt >= 0 else { throw BookmarkError.invalidData("书签标题、时间或排序无效。") }
            guard BookmarkURL.isValid(bookmark.url) else { throw BookmarkError.invalidData("书签网址必须是有效的 http 或 https 地址。") }
            guard bookmark.groupId == nil || groupIDs.contains(bookmark.groupId!) else { throw BookmarkError.invalidData("书签引用了不存在的文件夹。") }
        }
        return self
    }

    public static func decode(_ data: Data) throws -> BookmarkDocument {
        do { return try JSONDecoder().decode(BookmarkDocument.self, from: data).validated() }
        catch let error as BookmarkError { throw error }
        catch { throw BookmarkError.invalidData("无法解析书签文件，必要字段缺失或 JSON 已损坏。") }
    }
    public func encoded() throws -> Data {
        _ = try validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum BookmarkURL {
    public static func isValid(_ value: String) -> Bool {
        guard !value.contains(where: { $0.isWhitespace }),
              let parts = URLComponents(string: value),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.url != nil else { return false }
        return true
    }

    public static func normalize(_ value: String) throws -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.contains("://") {
            guard !result.contains(where: { $0.isWhitespace }),
                  let parts = URLComponents(string: "https://" + result), parts.user == nil, parts.password == nil,
                  let host = parts.host,
                  (host.contains(".") || host == "localhost" || (host.hasPrefix("[") && host.hasSuffix("]") && host.contains(":"))),
                  !host.hasPrefix("."), !host.hasSuffix(".") else {
                throw BookmarkError.invalidData("请输入有效网址，例如 example.com。")
            }
            result = "https://" + result
        }
        guard isValid(result) else { throw BookmarkError.invalidData("网址仅支持有效的 http 或 https 地址。") }
        return result
    }
}

public enum BookmarkError: LocalizedError, Equatable {
    case unsupportedFormat
    case invalidData(String)
    case unavailable(String)
    case conflict
    case busy
    case sameBackupLocation

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "该文件不是受支持的青蛙导航书签备份（格式版本 1）。"
        case .invalidData(let message): return message
        case .unavailable(let message): return message
        case .conflict: return "检测到外部更新，已载入最新数据。请重试本次修改；未提交的输入已保留。"
        case .busy: return "正在处理数据，请稍后重试。"
        case .sameBackupLocation: return "备份位置不能是正在使用的 bookmarks.json，请另选位置。"
        }
    }
}
