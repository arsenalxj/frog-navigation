import Foundation
import Darwin

/// 同时监听目录替换和主文件原地修改。没有定时轮询，隐藏界面也无需持续刷新。
final class DirectoryWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.frog.file-watcher", qos: .utility)
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private var directory: URL?
    private var signature = ""
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }

    func watch(_ directory: URL) {
        queue.async { [weak self] in
            guard let self else { return }
            self.directory = directory
            self.installSources()
        }
    }

    private func installSources() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        guard let directory else { return }
        signature = currentSignature()
        for url in [directory.deletingLastPathComponent(), directory, directory.appendingPathComponent("bookmarks.json")] {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .extend, .attrib, .revoke], queue: queue)
            let watchesParent = url == directory.deletingLastPathComponent()
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if watchesParent && self.currentSignature() == self.signature { return }
                self.scheduleChange()
            }
            source.setCancelHandler { close(descriptor) }
            sources.append(source)
            source.resume()
        }
    }

    private func currentSignature() -> String {
        guard let directory else { return "" }
        let paths: [URL] = [directory, directory.appendingPathComponent("bookmarks.json")]
        let keys: [FileAttributeKey] = [.systemFileNumber, .size, .modificationDate, .posixPermissions]
        return paths.map { url -> String in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "missing" }
            return keys.map { key in
                if let date = attributes[key] as? Date { return String(date.timeIntervalSince1970) }
                return "\(attributes[key] ?? "")"
            }.joined(separator: ":")
        }.joined(separator: "|")
    }

    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.installSources()
            self.onChange()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    deinit {
        pending?.cancel()
        sources.forEach { $0.cancel() }
    }
}
