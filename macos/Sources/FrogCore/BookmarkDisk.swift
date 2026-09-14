import Foundation
import Darwin

struct DiskSnapshot: Sendable {
    let document: BookmarkDocument
    let bytes: Data
}

enum DiskFailure: Error {
    case externalChange(DiskSnapshot)
}

/// 所有书签磁盘读写均在此 actor 的串行执行器上完成。
actor BookmarkDisk {
    private let manager = FileManager.default
    private var directory: URL?
    private var snapshot: Data?
    private var unavailableReason: String?
    private let sizeLimit = 32 * 1_024 * 1_024

    func open(_ target: URL, createIfMissing: Bool, createDirectory: Bool = false, seed: BookmarkDocument = .init()) throws -> DiskSnapshot {
        if createDirectory { try manager.createDirectory(at: target, withIntermediateDirectories: true) }
        try checkDirectory(target)
        let url = target.appendingPathComponent("bookmarks.json")
        let result: DiskSnapshot
        if manager.fileExists(atPath: url.path) {
            result = try read(url)
        } else if createIfMissing {
            let data = try seed.encoded()
            try atomicWrite(data, to: url, expected: nil, onlyIfMissing: true)
            result = DiskSnapshot(document: seed, bytes: data)
        } else {
            throw BookmarkError.unavailable("当前数据文件暂时不可用，已保留所选目录。请恢复 bookmarks.json 后重试，或选择其他目录。")
        }
        directory = target
        snapshot = result.bytes
        unavailableReason = nil
        return result
    }

    func reload() throws -> DiskSnapshot {
        guard let directory else { throw BookmarkError.unavailable("数据目录尚未成功载入，请先重试读取。") }
        do {
            try checkDirectory(directory)
            let current = try read(directory.appendingPathComponent("bookmarks.json"))
            snapshot = current.bytes
            unavailableReason = nil
            return current
        } catch {
            unavailableReason = describe(error)
            throw error
        }
    }

    func save(_ document: BookmarkDocument) throws -> DiskSnapshot {
        guard let directory, let snapshot else { throw BookmarkError.unavailable("数据尚未成功载入，无法保存。请先重试读取。") }
        if let unavailableReason { throw BookmarkError.unavailable(unavailableReason) }
        do {
            try checkDirectory(directory)
            let bytes = try document.encoded()
            try atomicWrite(bytes, to: directory.appendingPathComponent("bookmarks.json"), expected: snapshot)
            self.snapshot = bytes
            return DiskSnapshot(document: document, bytes: bytes)
        } catch DiskFailure.externalChange(let current) {
            self.snapshot = current.bytes
            throw DiskFailure.externalChange(current)
        } catch {
            unavailableReason = describe(error)
            throw error
        }
    }

    func export(to destination: URL) throws -> DiskSnapshot {
        guard let directory, let snapshot else { throw BookmarkError.unavailable("请先载入数据目录。") }
        let mainURL = directory.appendingPathComponent("bookmarks.json")
        if sameFile(mainURL, destination) { throw BookmarkError.sameBackupLocation }
        let current = DiskSnapshot(document: try BookmarkDocument.decode(snapshot), bytes: snapshot)
        try atomicWrite(try current.document.encoded(), to: destination, expected: nil)
        return current
    }

    func restore(from source: URL, into target: URL) throws -> DiskSnapshot {
        let restored = try read(source)
        try checkDirectory(target)
        try atomicWrite(restored.bytes, to: target.appendingPathComponent("bookmarks.json"), expected: nil)
        directory = target
        snapshot = restored.bytes
        unavailableReason = nil
        return restored
    }

    private func read(_ url: URL) throws -> DiskSnapshot {
        var coordinatorError: NSError?
        var result: Result<DiskSnapshot, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { coordinatedURL in
            result = Result { try self.readUncoordinated(coordinatedURL) }
        }
        if let coordinatorError { throw BookmarkError.unavailable("读取书签文件失败：\(coordinatorError.localizedDescription)") }
        guard let result else { throw BookmarkError.unavailable("无法读取书签文件，请检查文件权限。") }
        return try result.get()
    }

    private func readUncoordinated(_ url: URL) throws -> DiskSnapshot {
        guard manager.fileExists(atPath: url.path) else {
            throw BookmarkError.unavailable("bookmarks.json 暂时缺失，已保留当前数据并暂停写入。请恢复文件后重试。")
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw BookmarkError.invalidData("书签数据必须是普通 JSON 文件。") }
        guard (values.fileSize ?? 0) <= sizeLimit else { throw BookmarkError.invalidData("书签文件超过 32 MB，无法读取。") }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= sizeLimit else { throw BookmarkError.invalidData("书签文件超过 32 MB，无法读取。") }
        return DiskSnapshot(document: try BookmarkDocument.decode(bytes), bytes: bytes)
    }

    private func checkDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BookmarkError.unavailable("数据目录不存在或暂时不可用：\(url.path)")
        }
        guard manager.isReadableFile(atPath: url.path), manager.isWritableFile(atPath: url.path) else {
            throw BookmarkError.unavailable("数据目录没有读写权限：\(url.path)")
        }
        let main = url.appendingPathComponent("bookmarks.json")
        if manager.fileExists(atPath: main.path),
           (!manager.isReadableFile(atPath: main.path) || !manager.isWritableFile(atPath: main.path)) {
            throw BookmarkError.unavailable("bookmarks.json 没有读写权限，请修改文件权限或选择其他目录。")
        }
    }

    private func atomicWrite(_ bytes: Data, to destination: URL, expected: Data?, onlyIfMissing: Bool = false) throws {
        guard bytes.count <= sizeLimit else {
            throw BookmarkError.invalidData("书签数据超过 32 MB，无法保存。请减少数据量后重试；原文件保持不变。")
        }
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".frog-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw BookmarkError.unavailable("无法在目标目录创建临时文件，请检查写入权限。")
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: bytes); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }

        var coordinatorError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinatorError) { coordinatedURL in
            result = Result {
                if let expected {
                    let current = try self.readUncoordinated(coordinatedURL)
                    guard current.bytes == expected else { throw DiskFailure.externalChange(current) }
                } else if onlyIfMissing && self.manager.fileExists(atPath: coordinatedURL.path) {
                    throw BookmarkError.unavailable("目标目录刚收到外部数据，请重新选择该目录。")
                }
                guard rename(temporary.path, coordinatedURL.path) == 0 else {
                    throw BookmarkError.unavailable("保存文件失败：\(String(cString: strerror(errno)))")
                }
                let directoryFD = Darwin.open(parent.path, O_RDONLY)
                if directoryFD >= 0 { _ = fsync(directoryFD); close(directoryFD) }
            }
        }
        if let coordinatorError { throw BookmarkError.unavailable("保存文件失败：\(coordinatorError.localizedDescription)") }
        guard let result else { throw BookmarkError.unavailable("无法完成原子保存，请重试。") }
        try result.get()
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.standardizedFileURL.resolvingSymlinksInPath() == rhs.standardizedFileURL.resolvingSymlinksInPath() { return true }
        let leftID = try? lhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
        let rightID = try? rhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
        return leftID != nil && leftID == rightID
    }

    private func describe(_ error: Error) -> String { "\(error.localizedDescription) 已保留当前数据，请重试读取后继续。" }
}
