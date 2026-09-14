import AppKit
import Carbon
import Darwin

/// 仅在进程内保留最后一个真实目录。虚拟位置及 Finder 关窗不清空缓存。
struct FinderJumpLocationCache {
    private(set) var lastDirectory: URL?

    mutating func accept(_ candidate: URL?, isDirectory: (URL) -> Bool = Self.isRealDirectory) {
        guard let candidate, candidate.isFileURL,
              !["savedsearch", "smartfolder"].contains(candidate.pathExtension.lowercased()),
              isDirectory(candidate) else { return }
        lastDirectory = candidate.standardizedFileURL
    }

    func validDirectory(isDirectory: (URL) -> Bool = Self.isRealDirectory) -> URL? {
        guard let lastDirectory, isDirectory(lastDirectory) else { return nil }
        return lastDirectory
    }

    static func isRealDirectory(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// 使用 Finder.sdef 的公开脚本对象：URL of target of Finder window 1。
/// 直接发只读 Apple Event，无脚本文本插值，也不启动或激活 Finder。
enum FinderJumpFinderReader {
    static func currentDirectory(pid: pid_t) -> URL? {
        let window = object(want: code("brow"), form: code("indx"), key: NSAppleEventDescriptor(int32: 1), container: .null())
        let target = property(code("fvtg"), container: window)
        let urlProperty = property(code("pURL"), container: target)
        let request = NSAppleEventDescriptor(eventClass: code("core"), eventID: code("getd"),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid), returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        request.setParam(urlProperty, forKeyword: AEKeyword(keyDirectObject))
        // neverInteract 不会在后台弹出交互式脚本错误；授权由设置中的显式入口完成。
        guard let reply = try? request.sendEvent(options: [.waitForReply, .neverInteract, .dontRecord], timeout: 2),
              (reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0) == 0,
              let string = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string), url.isFileURL else { return nil }
        return url
    }

    private static func property(_ key: OSType, container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        object(want: code("prop"), form: code("prop"), key: NSAppleEventDescriptor(typeCode: key), container: container)
    }

    private static func object(want: OSType, form: OSType, key: NSAppleEventDescriptor,
                               container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: code("want"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: code("form"))
        record.setDescriptor(key, forKeyword: code("seld"))
        record.setDescriptor(container, forKeyword: code("from"))
        return record.coerce(toDescriptorType: code("obj "))!
    }

    private static func code(_ value: String) -> OSType {
        value.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }
}

/// 目录或其父目录的 vnode 变化触发有效性检查；闲置时没有定时任务。
final class FinderJumpDirectoryWatch {
    private let queue: DispatchQueue
    private var sources: [DispatchSourceFileSystemObject] = []
    private var directory: URL?
    private let onChange: () -> Void

    init(queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.queue = queue; self.onChange = onChange
    }

    func watch(_ url: URL?) {
        guard directory != url else { return }
        stop(); directory = url
        guard let url else { return }
        for watched in Set([url, url.deletingLastPathComponent()]) {
            let descriptor = open(watched.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.delete, .rename, .revoke, .attrib, .write], queue: queue)
            source.setEventHandler { [weak self] in self?.onChange() }
            source.setCancelHandler { close(descriptor) }
            sources.append(source); source.resume()
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }; sources.removeAll(); directory = nil
    }

    deinit { sources.forEach { $0.cancel() } }
}
