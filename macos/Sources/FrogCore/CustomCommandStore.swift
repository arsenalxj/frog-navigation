import Foundation
import Darwin

/// 本机命令独立存储；读取失败或外部修改后必须重新读取，才能恢复写入。
public actor CustomCommandStore {
    private struct Document: Codable {
        var schemaVersion = 1
        var commands: [CustomCommand]
    }

    private let directory: URL
    private let manager = FileManager.default
    private let sizeLimit = 32 * 1_024 * 1_024
    private var loaded = false
    private var snapshot: Data?

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(reservedNames: Set<String>) throws -> [CustomCommand] {
        loaded = false
        let bytes = try readCoordinated(directory.appendingPathComponent("commands-macos.json"))
        let commands: [CustomCommand]
        if let bytes {
            let document: Document
            do { document = try JSONDecoder().decode(Document.self, from: bytes) }
            catch { throw CustomCommandError.invalidData("命令配置格式损坏，原文件已保留") }
            guard document.schemaVersion == 1 else {
                throw CustomCommandError.invalidData("命令配置版本不受支持，原文件已保留")
            }
            commands = try validated(document.commands, reservedNames: reservedNames)
        } else {
            commands = []
        }
        snapshot = bytes
        loaded = true
        return commands
    }

    public func save(_ commands: [CustomCommand], reservedNames: Set<String>) throws {
        guard loaded else {
            throw CustomCommandError.unavailable("命令配置尚未载入，请先执行 :retry")
        }
        let normalized = try validated(commands, reservedNames: reservedNames)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(Document(commands: normalized))
        guard bytes.count <= sizeLimit else {
            throw CustomCommandError.invalidData("命令配置超过 32 MB，原文件已保留")
        }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try atomicWrite(bytes, to: directory.appendingPathComponent("commands-macos.json"))
            snapshot = bytes
        } catch {
            loaded = false
            throw error
        }
    }

    private func validated(_ commands: [CustomCommand], reservedNames: Set<String>) throws -> [CustomCommand] {
        var names = Set<String>()
        return try commands.map { command in
            let command = try command.validated(reservedNames: reservedNames)
            guard names.insert(command.name).inserted else {
                throw CustomCommandError.invalidData("命令名“\(command.name)”重复")
            }
            return command
        }
    }

    private func readCoordinated(_ url: URL) throws -> Data? {
        var coordinatorError: NSError?
        var result: Result<Data?, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { coordinatedURL in
            result = Result { try self.readUncoordinated(coordinatedURL) }
        }
        if let coordinatorError {
            if isMissing(coordinatorError) { return nil }
            throw coordinatorError
        }
        guard let result else { throw CustomCommandError.unavailable("无法读取命令配置，请检查权限") }
        return try result.get()
    }

    private func readUncoordinated(_ url: URL) throws -> Data? {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                throw CustomCommandError.invalidData("命令配置须为普通 JSON 文件")
            }
            guard (values.fileSize ?? 0) <= sizeLimit else {
                throw CustomCommandError.invalidData("命令配置文件超过 32 MB，无法读取")
            }
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= sizeLimit else {
                throw CustomCommandError.invalidData("命令配置文件超过 32 MB，无法读取")
            }
            return bytes
        } catch {
            if isMissing(error) { return nil }
            throw error
        }
    }

    private func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)
    }

    private func atomicWrite(_ bytes: Data, to destination: URL) throws {
        let temporary = directory.appendingPathComponent(".frog-commands-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CustomCommandError.unavailable("无法创建临时文件，请检查写入权限")
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: bytes); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }

        var coordinatorError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinatorError) { coordinatedURL in
            result = Result {
                guard try self.readUncoordinated(coordinatedURL) == self.snapshot else {
                    throw CustomCommandError.externalChange
                }
                guard rename(temporary.path, coordinatedURL.path) == 0 else {
                    throw CustomCommandError.unavailable("保存失败：\(String(cString: strerror(errno)))")
                }
                let directoryFD = Darwin.open(self.directory.path, O_RDONLY)
                if directoryFD >= 0 { _ = fsync(directoryFD); close(directoryFD) }
            }
        }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw CustomCommandError.unavailable("保存失败，请重试") }
        try result.get()
    }
}
