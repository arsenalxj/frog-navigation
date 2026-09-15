import AppKit
import Combine
import Foundation

/// 共享缓存限制离屏图像占用；可见图标通过 VisibleIcon 持有展示结果。
@MainActor
public final class IconStore: ObservableObject {
    @Published public private(set) var revision = 0
    private let images: NSCache<NSString, NSImage>
    private let pipeline: IconPipeline
    private let networkingEnabled: Bool
    private var failed = Set<String>()
    private var visibleIcons: [String: NSHashTable<VisibleIcon>] = [:]
    private var tasks: [String: (id: UUID, force: Bool, task: Task<Void, Never>)] = [:]

    public convenience init(cacheDirectory: URL? = nil, networkingEnabled: Bool = true) {
        let directory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Frog", isDirectory: true)
        self.init(cacheDirectory: directory, networkingEnabled: networkingEnabled, client: BoundedHTTPClient())
    }

    init(cacheDirectory: URL, networkingEnabled: Bool, client: any IconHTTPFetching,
         images: NSCache<NSString, NSImage> = NSCache<NSString, NSImage>(),
         cache: (any IconCaching)? = nil) {
        self.images = images
        self.networkingEnabled = networkingEnabled
        pipeline = IconPipeline(cache: cache ?? IconCache(directory: cacheDirectory), client: client)
        images.countLimit = 160
        images.totalCostLimit = 24 * 1024 * 1024
    }

    public func image(for url: String) -> NSImage? {
        guard let key = IconURL.valid(url)?.absoluteString else { return nil }
        return images.object(forKey: key as NSString)
            ?? visibleIcons[key]?.allObjects.lazy.compactMap { $0.image(for: key) }.first
    }

    public func load(_ url: String, force: Bool = false) async {
        guard let page = IconURL.valid(url) else { return }
        let key = page.absoluteString
        if !force, image(for: key) != nil { return }
        if let existing = tasks[key] {
            // 显式刷新升级当前任务，磁盘读取结束后继续请求网络。
            if force { tasks[key]?.force = true }
            await existing.task.value
            return
        }
        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            // 在唤醒等待者前清理，避免后来的 force 加入已结束的缓存读取。
            defer { if tasks[key]?.id == taskID { tasks[key] = nil } }
            if let cached = await pipeline.cached(page) {
                guard !Task.isCancelled else { return }
                display(cached, for: key)
                if tasks[key]?.force != true { return }
            }
            guard !Task.isCancelled, networkingEnabled, tasks[key]?.force == true || !failed.contains(key) else { return }
            let result = await pipeline.fetch(page)
            guard !Task.isCancelled else { return }
            if let result {
                failed.remove(key)
                display(result, for: key)
            } else { failed.insert(key) }
        }
        tasks[key] = (taskID, force, task)
        await task.value
    }

    /// 启动台收起后释放解码图像；磁盘缓存仍在，下次显示按需恢复。
    public func trimMemory() {
        for pending in tasks.values { pending.task.cancel() }
        tasks.removeAll()
        images.removeAllObjects()
        let references = visibleIcons.values.flatMap(\.allObjects)
        visibleIcons.removeAll()
        for reference in references { reference.release() }
        revision &+= 1
    }

    fileprivate func attach(_ reference: VisibleIcon, for key: String) {
        let existing = image(for: key)
        let references = visibleIcons[key] ?? NSHashTable<VisibleIcon>.weakObjects()
        references.add(reference)
        visibleIcons[key] = references
        reference.receive(existing)
    }

    fileprivate func detach(_ reference: VisibleIcon, for key: String) {
        guard let references = visibleIcons[key] else { return }
        references.remove(reference)
        if references.allObjects.isEmpty { visibleIcons[key] = nil }
    }

    private func display(_ icon: DecodedIcon, for key: String) {
        let image = NSImage(cgImage: icon.image, size: NSSize(width: icon.image.width, height: icon.image.height))
        images.setObject(image, forKey: key as NSString, cost: icon.image.bytesPerRow * icon.image.height)
        for reference in visibleIcons[key]?.allObjects ?? [] { reference.receive(image) }
        revision &+= 1
    }
}

/// 单个界面图标的展示生命周期。
@MainActor
public final class VisibleIcon: ObservableObject {
    @Published private var heldImage: NSImage?
    private weak var store: IconStore?
    private var key: String?
    private var requestID = UUID()

    public init() {}

    public func image(for url: String) -> NSImage? {
        guard let key, key == IconURL.valid(url)?.absoluteString else { return nil }
        return heldImage
    }

    public func load(_ url: String, from store: IconStore, visible: Bool = true) async {
        guard !Task.isCancelled else { return }
        release()
        guard visible, let key = IconURL.valid(url)?.absoluteString else { return }
        self.store = store
        self.key = key
        let requestID = self.requestID
        store.attach(self, for: key)
        await withTaskCancellationHandler {
            await store.load(key)
            if Task.isCancelled { release(ifCurrent: requestID) }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(ifCurrent: requestID) }
        }
    }

    public func release() {
        if let key { store?.detach(self, for: key) }
        requestID = UUID()
        store = nil
        key = nil
        heldImage = nil
    }

    private func release(ifCurrent requestID: UUID) {
        guard self.requestID == requestID else { return }
        release()
    }

    fileprivate func receive(_ image: NSImage?) { heldImage = image }
}

private actor IconPipeline {
    private let cache: any IconCaching
    private let client: any IconHTTPFetching

    init(cache: any IconCaching, client: any IconHTTPFetching) { self.cache = cache; self.client = client }

    func cached(_ page: URL) async -> DecodedIcon? { await cache.read(for: page) }

    func fetch(_ page: URL) async -> DecodedIcon? {
        var finalPage = page
        var candidates: [IconCandidate] = []
        do {
            let response = try await client.fetch(page, kind: .html)
            finalPage = response.finalURL
            let html = String(data: response.data, encoding: .utf8) ?? String(data: response.data, encoding: .isoLatin1) ?? ""
            candidates = IconHTMLParser.candidates(in: html, finalPageURL: finalPage)
        } catch is CancellationError { return nil }
        catch { /* 网页不可读取时仍可使用站点根目录图标。 */ }

        var best: (icon: DecodedIcon, source: URL)?
        for candidate in candidates.prefix(8) {
            if Task.isCancelled { return nil }
            guard let response = try? await client.fetch(candidate.url, kind: .image),
                  let decoded = DecodedIcon.decode(response.data) else { continue }
            if decoded.pixelSize > (best?.icon.pixelSize ?? 0) { best = (decoded, response.finalURL) }
            if decoded.pixelSize >= 128 { break }
        }
        if best == nil, let fallback = IconURL.rootIcon(for: finalPage),
           let response = try? await client.fetch(fallback, kind: .image), let decoded = DecodedIcon.decode(response.data) {
            best = (decoded, response.finalURL)
        }
        if best == nil, !Task.isCancelled, let originalFallback = IconURL.rootIcon(for: page),
           originalFallback != IconURL.rootIcon(for: finalPage),
           let response = try? await client.fetch(originalFallback, kind: .image), let decoded = DecodedIcon.decode(response.data) {
            best = (decoded, response.finalURL)
        }
        guard !Task.isCancelled, let best else { return nil }
        // 缓存落盘失败不影响当前会话展示，也不替换用户的书签数据。
        try? await cache.save(best.icon, originalPage: page, finalPage: finalPage, resource: best.source)
        return best.icon
    }
}
