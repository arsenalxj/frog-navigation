import Foundation

extension BookmarkDocument {
    @discardableResult
    public mutating func upsertBookmark(id: String? = nil, title: String, url: String,
                                        groupID: String?, newGroupName: String? = nil) throws -> String {
        var next = self
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120 else { throw BookmarkError.invalidData("标题不能为空，且不能超过 120 个字符。") }
        let url = try BookmarkURL.normalize(url)
        var groupID = groupID
        if let newGroupName { groupID = try next.addGroup(name: newGroupName) }
        try next.requireGroup(groupID)
        let bookmarkID: String
        if let id {
            guard let index = next.bookmarks.firstIndex(where: { $0.id == id }) else {
                throw BookmarkError.invalidData("该书签已不存在，请重新选择。")
            }
            bookmarkID = id
            let previousGroup = next.bookmarks[index].groupId
            next.bookmarks[index].title = title
            next.bookmarks[index].url = url
            if previousGroup != groupID { try next.moveBookmark(id: id, to: groupID) }
        } else {
            next.normalizeOrder(in: groupID)
            let bookmark = Bookmark(title: title, url: url, groupId: groupID,
                                    order: next.nextOrder(in: groupID))
            bookmarkID = bookmark.id
            next.bookmarks.append(bookmark)
        }
        self = try next.validated()
        return bookmarkID
    }

    @discardableResult
    public mutating func addGroup(name: String) throws -> String {
        let name = try checkedGroupName(name)
        normalizeOrder(in: nil)
        let group = BookmarkGroup(name: name, order: nextOrder(in: nil))
        groups.append(group)
        return group.id
    }

    public mutating func renameGroup(id: String, name: String) throws {
        let name = try checkedGroupName(name)
        guard let index = groups.firstIndex(where: { $0.id == id }) else {
            throw BookmarkError.invalidData("该文件夹已不存在，请重新选择。")
        }
        groups[index].name = name
    }

    public mutating func deleteBookmark(id: String) throws {
        guard let item = bookmarks.first(where: { $0.id == id }) else {
            throw BookmarkError.invalidData("该书签已不存在。")
        }
        bookmarks.removeAll { $0.id == id }
        normalizeOrder(in: item.groupId)
    }

    public mutating func deleteGroup(id: String) throws {
        guard groups.contains(where: { $0.id == id }) else { throw BookmarkError.invalidData("该文件夹已不存在。") }
        guard !bookmarks.contains(where: { $0.groupId == id }) else {
            throw BookmarkError.invalidData("请先移出或删除文件夹内的书签，再删除文件夹。")
        }
        groups.removeAll { $0.id == id }
        normalizeOrder(in: nil)
    }

    public mutating func moveBookmark(id: String, to groupID: String?, before targetID: String? = nil) throws {
        try requireGroup(groupID)
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else {
            throw BookmarkError.invalidData("该书签已不存在。")
        }
        guard targetID != id else { return }
        let previousGroup = bookmarks[index].groupId
        var ids = groupID == nil ? rootItems.map(\.id) : bookmarks(in: groupID).map(\.id)
        ids.removeAll { $0 == id }
        if let targetID {
            guard let insertion = ids.firstIndex(of: targetID) else {
                throw BookmarkError.invalidData("拖拽目标已改变，请重试。")
            }
            ids.insert(id, at: insertion)
        } else { ids.append(id) }
        bookmarks[index].groupId = groupID
        if previousGroup != groupID { normalizeOrder(in: previousGroup) }
        assignOrder(ids: ids, groupID: groupID)
    }

    public mutating func reorderRoot(ids: [String]) throws {
        guard Set(ids).count == ids.count, Set(ids) == Set(rootItems.map(\.id)) else {
            throw BookmarkError.invalidData("根目录内容已改变，请重试排序。")
        }
        assignOrder(ids: ids, groupID: nil)
    }

    public mutating func reorderGroup(id: String, bookmarkIDs: [String]) throws {
        try requireGroup(id)
        guard Set(bookmarkIDs).count == bookmarkIDs.count,
              Set(bookmarkIDs) == Set(bookmarks(in: id).map(\.id)) else {
            throw BookmarkError.invalidData("文件夹内容已改变，请重试排序。")
        }
        assignOrder(ids: bookmarkIDs, groupID: id)
    }

    @discardableResult
    public mutating func mergeBookmarks(sourceID: String, targetID: String) throws -> String {
        guard sourceID != targetID,
              let sourceIndex = bookmarks.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = bookmarks.firstIndex(where: { $0.id == targetID }),
              bookmarks[targetIndex].groupId == nil else {
            throw BookmarkError.invalidData("只能在根目录将两条不同书签组成文件夹。")
        }
        let oldSourceGroup = bookmarks[sourceIndex].groupId
        let group = BookmarkGroup(name: "新建文件夹", order: bookmarks[targetIndex].order)
        var rootIDs = rootItems.map(\.id).filter { $0 != sourceID }
        if let target = rootIDs.firstIndex(of: targetID) { rootIDs[target] = group.id }
        groups.append(group)
        bookmarks[targetIndex].groupId = group.id
        bookmarks[targetIndex].order = 0
        bookmarks[sourceIndex].groupId = group.id
        bookmarks[sourceIndex].order = 1
        assignOrder(ids: rootIDs, groupID: nil)
        if let oldSourceGroup { normalizeOrder(in: oldSourceGroup) }
        return group.id
    }

    private func checkedGroupName(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 120 else { throw BookmarkError.invalidData("文件夹名称不能为空，且不能超过 120 个字符。") }
        return value
    }
    private func requireGroup(_ id: String?) throws {
        guard id == nil || groups.contains(where: { $0.id == id }) else { throw BookmarkError.invalidData("所选文件夹已不存在。") }
    }
    private func nextOrder(in groupID: String?) -> Int {
        let orders = groupID == nil ? rootItems.map(\.order) : bookmarks(in: groupID).map(\.order)
        return (orders.max() ?? -1) + 1
    }
    private mutating func normalizeOrder(in groupID: String?) {
        let ids = groupID == nil ? rootItems.map(\.id) : bookmarks(in: groupID).map(\.id)
        assignOrder(ids: ids, groupID: groupID)
    }
    private mutating func assignOrder(ids: [String], groupID: String?) {
        let positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        for index in bookmarks.indices where bookmarks[index].groupId == groupID {
            if let order = positions[bookmarks[index].id] { bookmarks[index].order = order }
        }
        if groupID == nil {
            for index in groups.indices {
                if let order = positions[groups[index].id] { groups[index].order = order }
            }
        }
    }
}
