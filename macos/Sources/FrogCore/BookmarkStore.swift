import Foundation
import Combine

@MainActor
public final class BookmarkStore: ObservableObject {
    @Published public private(set) var document = BookmarkDocument()
    @Published public private(set) var directory: URL
    @Published public var issue: String?
    @Published public private(set) var isBusy = false
    @Published public private(set) var isLoaded = false

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Frog", isDirectory: true)
    }
    public static let directoryPreferenceKey = "Frog.dataDirectory"
    public static let directoryBookmarkKey = "Frog.dataDirectoryBookmark"

    private let disk = BookmarkDisk()
    private let defaults: UserDefaults
    private let persistDirectory: Bool
    private var initialMayCreate: Bool
    private var initialLocationError: String?
    private var securityScopedURL: URL?
    private var operationActive = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var watcher: DirectoryWatcher?

    public init(directoryOverride: URL? = nil, defaults: UserDefaults = .standard, persistDirectory: Bool = true) {
        self.defaults = defaults
        self.persistDirectory = persistDirectory
        let savedPath = defaults.string(forKey: Self.directoryPreferenceKey)
        initialMayCreate = directoryOverride != nil || savedPath == nil
        directory = directoryOverride ?? savedPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultDirectory
        if directoryOverride == nil, savedPath != nil,
           let bookmark = defaults.data(forKey: Self.directoryBookmarkKey) {
            do {
                var stale = false
                let resolved = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                       relativeTo: nil, bookmarkDataIsStale: &stale)
                directory = resolved
                if resolved.startAccessingSecurityScopedResource() { securityScopedURL = resolved }
                if stale, persistDirectory,
                   let refreshed = try? resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    defaults.set(refreshed, forKey: Self.directoryBookmarkKey)
                }
            } catch {
                initialLocationError = "无法恢复数据目录访问权限。请在设置中重新选择该目录：\(directory.path)"
            }
        }
    }

    public func clearIssue() { issue = nil }

    public func load() async {
        await acquire()
        defer { release() }
        do {
            if let initialLocationError { throw BookmarkError.unavailable(initialLocationError) }
            let result = try await disk.open(directory, createIfMissing: initialMayCreate,
                                             createDirectory: initialMayCreate)
            document = result.document
            isLoaded = true
            initialMayCreate = false
            issue = nil
            rememberDirectory(directory)
            installWatcher()
        } catch { issue = error.localizedDescription }
    }

    public func reloadIfChanged() async {
        guard isLoaded else { await load(); return }
        await acquire()
        defer { release() }
        do {
            let result = try await disk.reload()
            if document != result.document { document = result.document }
            // 冲突提示保留到用户重试，文件监听回调不会瞬间抹去保存失败原因。
            if issue != BookmarkError.conflict.localizedDescription { issue = nil }
        } catch { issue = error.localizedDescription }
    }

    public func apply(_ mutation: (inout BookmarkDocument) throws -> Void) async throws {
        await acquire()
        defer { release() }
        do {
            guard isLoaded else { throw BookmarkError.unavailable("数据尚未成功载入，请先重试读取或选择其他目录。") }
            var next = document
            try mutation(&next)
            _ = try next.validated()
            let result = try await disk.save(next)
            document = result.document
            issue = nil
        } catch DiskFailure.externalChange(let latest) {
            document = latest.document
            issue = BookmarkError.conflict.localizedDescription
            throw BookmarkError.conflict
        } catch {
            issue = error.localizedDescription
            throw error
        }
    }

    public func switchDirectory(_ target: URL) async throws {
        await acquire()
        defer { release() }
        let target = target.standardizedFileURL.resolvingSymlinksInPath()
        if target == directory.standardizedFileURL.resolvingSymlinksInPath(), initialLocationError == nil, isLoaded { return }
        let accessStarted = target.startAccessingSecurityScopedResource()
        do {
            let result = try await disk.open(target, createIfMissing: true, seed: document)
            securityScopedURL?.stopAccessingSecurityScopedResource()
            securityScopedURL = accessStarted ? target : nil
            directory = target
            document = result.document
            initialMayCreate = false
            initialLocationError = nil
            isLoaded = true
            issue = nil
            rememberDirectory(target)
            installWatcher()
        } catch {
            if accessStarted { target.stopAccessingSecurityScopedResource() }
            issue = error.localizedDescription
            throw error
        }
    }

    public func exportBackup(to destination: URL) async throws {
        await acquire()
        defer { release() }
        let accessStarted = destination.startAccessingSecurityScopedResource()
        defer { if accessStarted { destination.stopAccessingSecurityScopedResource() } }
        do {
            let current = try await disk.reload()
            if document != current.document { document = current.document }
            let result = try await disk.export(to: destination)
            if document != result.document { document = result.document }
            issue = nil
        } catch { issue = error.localizedDescription; throw error }
    }

    public func restoreBackup(from source: URL) async throws {
        await acquire()
        defer { release() }
        let accessStarted = source.startAccessingSecurityScopedResource()
        defer { if accessStarted { source.stopAccessingSecurityScopedResource() } }
        do {
            if let initialLocationError { throw BookmarkError.unavailable(initialLocationError) }
            let result = try await disk.restore(from: source, into: directory)
            document = result.document
            isLoaded = true
            initialMayCreate = false
            issue = nil
            rememberDirectory(directory)
            installWatcher()
        } catch { issue = error.localizedDescription; throw error }
    }

    private func acquire() async {
        if operationActive { await withCheckedContinuation { waiters.append($0) } }
        else { operationActive = true; isBusy = true }
    }
    private func release() {
        if !waiters.isEmpty { waiters.removeFirst().resume() }
        else { operationActive = false; isBusy = false }
    }
    private func rememberDirectory(_ target: URL) {
        guard persistDirectory else { return }
        defaults.set(target.path, forKey: Self.directoryPreferenceKey)
        if let bookmark = try? target.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(bookmark, forKey: Self.directoryBookmarkKey)
        } else { defaults.removeObject(forKey: Self.directoryBookmarkKey) }
    }
    private func installWatcher() {
        if watcher == nil {
            watcher = DirectoryWatcher { [weak self] in Task { @MainActor [weak self] in await self?.reloadIfChanged() } }
        }
        watcher?.watch(directory)
    }
    deinit { securityScopedURL?.stopAccessingSecurityScopedResource() }
}
