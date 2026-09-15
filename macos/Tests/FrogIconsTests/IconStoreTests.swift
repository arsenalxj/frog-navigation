import AppKit
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FrogIcons

private actor FixtureIconClient: IconHTTPFetching {
    var responses: [String: IconHTTPResponse]
    private var requests: [String] = []

    init(_ responses: [String: IconHTTPResponse] = [:]) { self.responses = responses }

    func fetch(_ url: URL, kind: IconRequestKind) async throws -> IconHTTPResponse {
        requests.append(url.absoluteString)
        guard let response = responses[url.absoluteString] else { throw URLError(.notConnectedToInternet) }
        return response
    }

    func requestURLs() -> [String] { requests }
    func removeResponses() { responses.removeAll() }
    func setResponses(_ responses: [String: IconHTTPResponse]) { self.responses = responses }
}

private actor SuspendedIconClient: IconHTTPFetching {
    private let image: Data
    private let immediateImages: [String: Data]
    private let onImageRequested: (@Sendable () -> Void)?
    private var requests: [String] = []
    private var requested = false
    private var released = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var imageWaiter: CheckedContinuation<Void, Never>?

    init(image: Data, immediateImages: [String: Data] = [:], onImageRequested: (@Sendable () -> Void)? = nil) {
        self.image = image
        self.immediateImages = immediateImages
        self.onImageRequested = onImageRequested
    }

    func fetch(_ url: URL, kind: IconRequestKind) async throws -> IconHTTPResponse {
        requests.append(url.absoluteString)
        if kind == .html { return IconHTTPResponse(data: Data("<link rel=icon href='/icon.png'>".utf8), finalURL: url) }
        if let image = immediateImages[url.host ?? ""] { return IconHTTPResponse(data: image, finalURL: url) }
        requested = true
        onImageRequested?()
        startWaiter?.resume()
        startWaiter = nil
        if !released { await withCheckedContinuation { imageWaiter = $0 } }
        // 模拟取消时仍然返回结果的下载，检验展示层也正确拒绝迟到结果。
        return IconHTTPResponse(data: image, finalURL: url)
    }

    func waitUntilImageRequested() async {
        if !requested { await withCheckedContinuation { startWaiter = $0 } }
    }

    func releaseImage() {
        released = true
        imageWaiter?.resume()
        imageWaiter = nil
    }

    func requestURLs() -> [String] { requests }
}

/// 暂停真实磁盘读结果，保证多个刷新请求已经加入同一个普通加载。
private actor SuspendedIconCache: IconCaching {
    private let cache: IconCache
    private var started = false
    private var released = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var readWaiter: CheckedContinuation<Void, Never>?

    init(cache: IconCache) { self.cache = cache }

    func read(for page: URL) async -> DecodedIcon? {
        let result = await cache.read(for: page)
        if !started {
            started = true
            startWaiter?.resume()
            startWaiter = nil
            if !released { await withCheckedContinuation { readWaiter = $0 } }
        }
        return result
    }

    func save(_ icon: DecodedIcon, originalPage: URL, finalPage: URL, resource: URL) async throws {
        try await cache.save(icon, originalPage: originalPage, finalPage: finalPage, resource: resource)
    }

    func waitUntilRead() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }

    func releaseRead() {
        released = true
        readWaiter?.resume()
        readWaiter = nil
    }
}

final class IconStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrogIconsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    @MainActor
    func testCacheReuseAndIndexRecordsPageAndResourceSources() async throws {
        let page = "https://old.example/page"
        let finalPage = URL(string: "https://new.example/path/page")!
        let icon = URL(string: "https://cdn.example/icon.png")!
        let client = FixtureIconClient([
            page: IconHTTPResponse(data: Data("<link rel=icon href='https://cdn.example/icon.png' sizes='512x512'>".utf8), finalURL: finalPage),
            icon.absoluteString: IconHTTPResponse(data: try png(width: 512, height: 512), finalURL: icon)
        ])
        let store = IconStore(cacheDirectory: directory, networkingEnabled: true, client: client)
        XCTAssertNil(store.image(for: page))
        await store.load(page)
        XCTAssertEqual(store.image(for: page)?.size.width, 256)
        XCTAssertGreaterThan(store.revision, 0)

        let index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("icons-index.json"))) as? [String: Any])
        let entries = try XCTUnwrap(index["entries"] as? [String: [String: Any]])
        let entry = try XCTUnwrap(entries.values.first)
        XCTAssertEqual(entry["originalPageURL"] as? String, page)
        XCTAssertEqual(entry["finalPageURL"] as? String, finalPage.absoluteString)
        XCTAssertEqual(entry["resourceURL"] as? String, icon.absoluteString)
        XCTAssertTrue((entry["relativePath"] as? String)?.hasPrefix("icons/") == true)
        XCTAssertFalse((entry["relativePath"] as? String)?.hasPrefix("/") == true)

        let offline = FixtureIconClient()
        let next = IconStore(cacheDirectory: directory, networkingEnabled: true, client: offline)
        await next.load(page)
        XCTAssertNotNil(next.image(for: page))
        let offlineRequests = await offline.requestURLs()
        XCTAssertTrue(offlineRequests.isEmpty)
        next.trimMemory()
        XCTAssertNil(next.image(for: page))
        await next.load(page)
        XCTAssertNotNil(next.image(for: page))
    }

    @MainActor
    func testLoginRedirectFallsBackToOriginalSiteIcon() async throws {
        let page = "https://private.example/page"
        let login = URL(string: "https://login.example/sign-in")!
        let originalIcon = URL(string: "https://private.example/favicon.ico")!
        let client = FixtureIconClient([
            page: IconHTTPResponse(data: Data("<html>Sign in</html>".utf8), finalURL: login),
            originalIcon.absoluteString: IconHTTPResponse(data: try png(width: 160, height: 160), finalURL: originalIcon)
        ])
        let store = IconStore(cacheDirectory: directory, networkingEnabled: true, client: client)

        await store.load(page, force: true)

        XCTAssertEqual(store.image(for: page)?.size.width, 160)
        let requests = await client.requestURLs()
        XCTAssertEqual(requests, [page, "https://login.example/favicon.ico", originalIcon.absoluteString])
        let cached = await IconCache(directory: directory).read(for: URL(string: page)!)
        XCTAssertEqual(cached?.pixelSize, 160)
    }

    @MainActor
    func testFinalSiteRootIconKeepsPriorityOverOriginalSite() async throws {
        let page = "https://old.example/page"
        let finalPage = URL(string: "https://new.example/page")!
        let finalIcon = URL(string: "https://new.example/favicon.ico")!
        let client = FixtureIconClient([
            page: IconHTTPResponse(data: Data("<html></html>".utf8), finalURL: finalPage),
            finalIcon.absoluteString: IconHTTPResponse(data: try png(width: 64, height: 64), finalURL: finalIcon)
        ])
        let store = IconStore(cacheDirectory: directory, networkingEnabled: true, client: client)

        await store.load(page)

        XCTAssertEqual(store.image(for: page)?.size.width, 64)
        let requests = await client.requestURLs()
        XCTAssertEqual(requests, [page, finalIcon.absoluteString])
    }

    @MainActor
    func testSameSiteRedirectRequestsFailedRootIconOnlyOnce() async {
        let page = "https://example.com/private"
        let client = FixtureIconClient([
            page: IconHTTPResponse(data: Data("<html>Sign in</html>".utf8), finalURL: URL(string: "https://example.com/login")!)
        ])
        let store = IconStore(cacheDirectory: directory, networkingEnabled: true, client: client)

        await store.load(page)

        XCTAssertNil(store.image(for: page))
        let requests = await client.requestURLs()
        XCTAssertEqual(requests, [page, "https://example.com/favicon.ico"])
    }

    @MainActor
    func testFailedRefreshPreservesOldIconAndDoesNotPoll() async throws {
        let page = "https://example.com/page"
        let root = "https://example.com/favicon.ico"
        let client = FixtureIconClient([root: IconHTTPResponse(data: try png(width: 96, height: 96), finalURL: URL(string: root)!)])
        let store = IconStore(cacheDirectory: directory, networkingEnabled: true, client: client)
        await store.load(page)
        let oldData = store.image(for: page)?.tiffRepresentation
        XCTAssertNotNil(oldData)
        await client.removeResponses()
        await store.load(page, force: true)
        XCTAssertEqual(store.image(for: page)?.tiffRepresentation, oldData)
        let previousRequests = await client.requestURLs().count
        await store.load(page)
        let currentRequests = await client.requestURLs().count
        XCTAssertEqual(previousRequests, currentRequests)
    }

    @MainActor
    func testOfflineAndInvalidURLsNeverIssueRequests() async {
        let client = FixtureIconClient()
        let store = IconStore(cacheDirectory: directory, networkingEnabled: false, client: client)
        await store.load("https://example.com/")
        await store.load("file:///tmp/icon.png", force: true)
        await store.load("javascript:alert(1)")
        XCTAssertNil(store.image(for: "https://example.com/"))
        let requests = await client.requestURLs()
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor
    func testFailureIsAttemptedOnceUntilExplicitRefresh() async {
        let client = FixtureIconClient()
        let store = IconStore(cacheDirectory: directory, networkingEnabled: true, client: client)
        let page = "https://example.com/"
        await store.load(page)
        await store.load(page)
        store.trimMemory()
        await store.load(page)
        let requests = await client.requestURLs()
        XCTAssertEqual(requests.count, 2) // 网页与根目录图标各尝试一次。
        await store.load(page, force: true)
        let refreshed = await client.requestURLs()
        XCTAssertEqual(refreshed.count, 4)
    }

    @MainActor
    func testCorruptPreferredIconTriesNextDeclarationBeforeRootFallback() async throws {
        let page = "https://example.com/"
        let client = FixtureIconClient([
            page: IconHTTPResponse(data: Data("<link rel=icon sizes='256x256' href='/broken.png'><link rel=icon sizes='64x64' href='/good.png'>".utf8), finalURL: URL(string: page)!),
            "https://example.com/broken.png": IconHTTPResponse(data: Data("not an image".utf8), finalURL: URL(string: "https://example.com/broken.png")!),
            "https://example.com/good.png": IconHTTPResponse(data: try png(width: 64, height: 64), finalURL: URL(string: "https://example.com/good.png")!)
        ])
        let store = IconStore(cacheDirectory: directory, networkingEnabled: true, client: client)
        await store.load(page)
        XCTAssertEqual(store.image(for: page)?.size.width, 64)
        let requests = await client.requestURLs()
        XCTAssertFalse(requests.contains("https://example.com/favicon.ico"))
    }

    @MainActor
    func testTrimCancelsPendingDisplayAndNextLoadCanRetry() async throws {
        let client = SuspendedIconClient(image: try png(width: 128, height: 128))
        let store = IconStore(cacheDirectory: directory, networkingEnabled: true, client: client)
        let page = "https://example.com/"
        let pending = Task { await store.load(page) }
        await client.waitUntilImageRequested()
        store.trimMemory()
        await client.releaseImage()
        await pending.value
        XCTAssertNil(store.image(for: page))
        await store.load(page)
        XCTAssertNotNil(store.image(for: page))
    }

    @MainActor
    func testVisibleImageSurvivesDeterministicMemoryCacheEviction() async throws {
        let page = "https://example.com/page"
        let root = "https://example.com/favicon.ico"
        let client = FixtureIconClient([root: IconHTTPResponse(data: try png(width: 96, height: 96), finalURL: URL(string: root)!)])
        let memory = NSCache<NSString, NSImage>()
        let store = IconStore(cacheDirectory: directory, networkingEnabled: true, client: client, images: memory)
        let visible = VisibleIcon()
        await visible.load(page, from: store)
        let oldImage = try XCTUnwrap(visible.image(for: page))

        memory.removeAllObjects()
        XCTAssertNil(memory.object(forKey: page as NSString))
        XCTAssertTrue(visible.image(for: page) === oldImage, "可见图标不能随共享缓存淘汰而消失")
        let requests = await client.requestURLs()
        XCTAssertEqual(requests.count, 2, "保留可见结果无需重新请求网络")
        visible.release()
        XCTAssertNil(visible.image(for: page))
    }

    @MainActor
    func testSuccessfulDownloadRetriesAfterCacheWriteFailureAndTrim() async throws {
        let page = "https://example.com/page"
        let root = "https://example.com/favicon.ico"
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data("file blocks cache directory".utf8).write(to: blocked)
        let client = FixtureIconClient([root: IconHTTPResponse(data: try png(width: 96, height: 96), finalURL: URL(string: root)!)])
        let store = IconStore(cacheDirectory: blocked, networkingEnabled: true, client: client)
        await store.load(page)
        XCTAssertNotNil(store.image(for: page))
        store.trimMemory()
        await store.load(page)
        XCTAssertNotNil(store.image(for: page), "落盘失败不能阻止成功图标重新下载")
        let requests = await client.requestURLs()
        XCTAssertEqual(requests.count, 4)
    }

    @MainActor
    func testSuccessfulDownloadRebuildsDeletedDiskCache() async throws {
        let page = "https://example.com/page"
        let root = "https://example.com/favicon.ico"
        let client = FixtureIconClient([root: IconHTTPResponse(data: try png(width: 96, height: 96), finalURL: URL(string: root)!)])
        let store = IconStore(cacheDirectory: directory, networkingEnabled: true, client: client)
        await store.load(page)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("icons"))
        store.trimMemory()
        await store.load(page)
        XCTAssertNotNil(store.image(for: page), "成功图标的缓存被清理后应能自动重建")
        let requests = await client.requestURLs()
        XCTAssertEqual(requests.count, 4)
    }

    @MainActor
    func testForceSuccessClearsFailureSuppressionForLaterCacheRebuild() async throws {
        let page = "https://example.com/page"
        let root = "https://example.com/favicon.ico"
        let client = FixtureIconClient()
        let store = IconStore(cacheDirectory: directory, networkingEnabled: true, client: client)
        await store.load(page)
        XCTAssertNil(store.image(for: page))
        await client.setResponses([root: IconHTTPResponse(data: try png(width: 96, height: 96), finalURL: URL(string: root)!)])
        await store.load(page, force: true)
        XCTAssertNotNil(store.image(for: page))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("icons"))
        store.trimMemory()
        await store.load(page)
        XCTAssertNotNil(store.image(for: page))
        let requests = await client.requestURLs()
        XCTAssertEqual(requests.count, 6)
    }

    @MainActor
    func testVisibleReferencesShareRefreshAndReleaseWhenHiddenOrTrimmed() async throws {
        let page = "https://example.com/page"
        let root = "https://example.com/favicon.ico"
        let client = FixtureIconClient([root: IconHTTPResponse(data: try png(width: 96, height: 96), finalURL: URL(string: root)!)])
        let memory = NSCache<NSString, NSImage>()
        let store = IconStore(cacheDirectory: directory, networkingEnabled: true, client: client, images: memory)
        let first = VisibleIcon(), second = VisibleIcon()
        await first.load(page, from: store)
        memory.removeAllObjects()
        await second.load(page, from: store)
        XCTAssertTrue(first.image(for: page) === second.image(for: page))
        XCTAssertNotNil(store.image(for: page), "拖拽浮层仍可同步读取可见图标")
        let requests = await client.requestURLs()
        XCTAssertEqual(requests.count, 2, "同 URL 的第二个可见引用复用结果")

        await client.setResponses([root: IconHTTPResponse(data: try png(width: 160, height: 160), finalURL: URL(string: root)!)])
        await store.load(page, force: true)
        XCTAssertEqual(first.image(for: page)?.size.width, 160)
        XCTAssertTrue(first.image(for: page) === second.image(for: page))

        await first.load(page, from: store, visible: false)
        XCTAssertNil(first.image(for: page))
        XCTAssertNotNil(second.image(for: page))
        store.trimMemory()
        XCTAssertNil(first.image(for: page))
        XCTAssertNil(second.image(for: page))
        XCTAssertNil(store.image(for: page))
        await second.load(page, from: store)
        XCTAssertEqual(second.image(for: page)?.size.width, 160)
    }

    @MainActor
    func testFailedRefreshPreservesVisibleImageWithoutMemoryOrDiskCache() async throws {
        let page = "https://example.com/page"
        let root = "https://example.com/favicon.ico"
        let client = FixtureIconClient([root: IconHTTPResponse(data: try png(width: 96, height: 96), finalURL: URL(string: root)!)])
        let memory = NSCache<NSString, NSImage>()
        let store = IconStore(cacheDirectory: directory, networkingEnabled: true, client: client, images: memory)
        let reference = VisibleIcon()
        await reference.load(page, from: store)
        let oldImage = try XCTUnwrap(reference.image(for: page))
        memory.removeAllObjects()
        try FileManager.default.removeItem(at: directory.appendingPathComponent("icons"))
        await client.removeResponses()
        await store.load(page, force: true)
        XCTAssertTrue(reference.image(for: page) === oldImage)
    }

    @MainActor
    func testURLChangeIgnoresLateResultAndOldTaskCancellation() async throws {
        let oldPage = "https://old.example/page", newPage = "https://new.example/page"
        let client = SuspendedIconClient(image: try png(width: 128, height: 128),
                                         immediateImages: ["new.example": try png(width: 64, height: 64)])
        let store = IconStore(cacheDirectory: directory, networkingEnabled: true, client: client)
        let reference = VisibleIcon()
        let oldLoad = Task { await reference.load(oldPage, from: store) }
        await client.waitUntilImageRequested()
        await reference.load(newPage, from: store)
        XCTAssertNil(reference.image(for: oldPage))
        XCTAssertEqual(reference.image(for: newPage)?.size.width, 64)
        oldLoad.cancel()
        await client.releaseImage()
        await oldLoad.value
        XCTAssertNil(reference.image(for: oldPage))
        XCTAssertEqual(reference.image(for: newPage)?.size.width, 64, "旧任务取消不能清掉新 URL 的结果")
    }

    @MainActor
    func testCancellingOneVisibleReferenceKeepsSharedLoadForAnother() async throws {
        let page = "https://example.com/page"
        let client = SuspendedIconClient(image: try png(width: 128, height: 128))
        let store = IconStore(cacheDirectory: directory, networkingEnabled: true, client: client)
        let first = VisibleIcon(), second = VisibleIcon()
        let firstLoad = Task { await first.load(page, from: store) }
        await client.waitUntilImageRequested()
        let started = expectation(description: "第二个可见引用开始订阅")
        let observation = second.objectWillChange.prefix(1).sink { started.fulfill() }
        let secondLoad = Task { await second.load(page, from: store) }
        await fulfillment(of: [started], timeout: 2)
        firstLoad.cancel()
        await client.releaseImage()
        await firstLoad.value
        await secondLoad.value
        XCTAssertNil(first.image(for: page))
        XCTAssertEqual(second.image(for: page)?.size.width, 128)
        let requests = await client.requestURLs()
        XCTAssertEqual(requests, [page, "https://example.com/icon.png"], "并发同 URL 只抓取一次")
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testTrimRejectsLateSharedResultAndAllowsBothReferencesToReload() async throws {
        let page = "https://example.com/page"
        let client = SuspendedIconClient(image: try png(width: 128, height: 128))
        let store = IconStore(cacheDirectory: directory, networkingEnabled: true, client: client)
        let first = VisibleIcon(), second = VisibleIcon()
        let firstLoad = Task { await first.load(page, from: store) }
        await client.waitUntilImageRequested()
        let started = expectation(description: "第二个可见引用开始订阅")
        let observation = second.objectWillChange.prefix(1).sink { started.fulfill() }
        let secondLoad = Task { await second.load(page, from: store) }
        await fulfillment(of: [started], timeout: 2)
        store.trimMemory()
        await client.releaseImage()
        await firstLoad.value
        await secondLoad.value
        XCTAssertNil(first.image(for: page))
        XCTAssertNil(second.image(for: page))
        XCTAssertNil(store.image(for: page))
        await first.load(page, from: store)
        await second.load(page, from: store)
        XCTAssertEqual(first.image(for: page)?.size.width, 128)
        XCTAssertTrue(first.image(for: page) === second.image(for: page))
        let requests = await client.requestURLs()
        XCTAssertEqual(requests.count, 4)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testConcurrentForceAfterDiskLoadFetchesOnceAndUpdatesVisibleIcon() async throws {
        let page = "https://example.com/page"
        let cache = try await suspendedCache(for: page)
        let networkStarted = expectation(description: "磁盘加载后的显式刷新必须请求网络")
        let client = SuspendedIconClient(image: try png(width: 160, height: 160),
                                         onImageRequested: { networkStarted.fulfill() })
        let store = IconStore(cacheDirectory: directory, networkingEnabled: true, client: client, cache: cache)
        let reference = VisibleIcon()
        let ordinary = Task { await reference.load(page, from: store) }
        await cache.waitUntilRead()
        let refreshes = await startConcurrentRefreshes(page, in: store)
        await cache.releaseRead()
        await fulfillment(of: [networkStarted], timeout: 2)
        XCTAssertEqual(reference.image(for: page)?.size.width, 96, "网络刷新期间继续显示磁盘旧图")
        await client.releaseImage()
        await ordinary.value
        for refresh in refreshes { await refresh.value }
        XCTAssertEqual(reference.image(for: page)?.size.width, 160)
        let requests = await client.requestURLs()
        XCTAssertEqual(requests, [page, "https://example.com/icon.png"], "等待磁盘加载的多个 force 合并为一次刷新")
    }

    @MainActor
    func testForceWaitersDoNotReviveDiskLoadAfterTrim() async throws {
        let page = "https://example.com/page"
        let cache = try await suspendedCache(for: page)
        let client = FixtureIconClient()
        let store = IconStore(cacheDirectory: directory, networkingEnabled: true, client: client, cache: cache)
        let reference = VisibleIcon()
        let ordinary = Task { await reference.load(page, from: store) }
        await cache.waitUntilRead()
        let refreshes = await startConcurrentRefreshes(page, in: store)
        store.trimMemory()
        await cache.releaseRead()
        await ordinary.value
        for refresh in refreshes { await refresh.value }
        XCTAssertNil(reference.image(for: page))
        XCTAssertNil(store.image(for: page))
        let requests = await client.requestURLs()
        XCTAssertTrue(requests.isEmpty, "trim 之后旧 force 等待者不能补发网络请求")
        await reference.load(page, from: store)
        XCTAssertEqual(reference.image(for: page)?.size.width, 96, "新的显示生命周期仍能正常读取缓存")
    }

    @MainActor
    func testConcurrentForceSharesOrdinaryNetworkRequest() async throws {
        let page = "https://example.com/page"
        let client = SuspendedIconClient(image: try png(width: 160, height: 160))
        let store = IconStore(cacheDirectory: directory, networkingEnabled: true, client: client)
        let ordinary = Task { await store.load(page) }
        await client.waitUntilImageRequested()
        let refreshes = await startConcurrentRefreshes(page, in: store)
        await client.releaseImage()
        await ordinary.value
        for refresh in refreshes { await refresh.value }
        XCTAssertEqual(store.image(for: page)?.size.width, 160)
        let requests = await client.requestURLs()
        XCTAssertEqual(requests, [page, "https://example.com/icon.png"], "已经进行网络请求时 force 复用同一次抓取")
    }

    @MainActor
    func testFailedConcurrentForceAfterDiskLoadDoesNotPoll() async throws {
        let page = "https://example.com/page"
        let cache = try await suspendedCache(for: page)
        let client = FixtureIconClient()
        let store = IconStore(cacheDirectory: directory, networkingEnabled: true, client: client, cache: cache)
        let reference = VisibleIcon()
        let ordinary = Task { await reference.load(page, from: store) }
        await cache.waitUntilRead()
        let refreshes = await startConcurrentRefreshes(page, in: store)
        await cache.releaseRead()
        await ordinary.value
        for refresh in refreshes { await refresh.value }
        XCTAssertEqual(reference.image(for: page)?.size.width, 96, "刷新失败保留旧图")
        let requests = await client.requestURLs()
        XCTAssertEqual(requests, [page, "https://example.com/favicon.ico"])
        try FileManager.default.removeItem(at: directory.appendingPathComponent("icons"))
        store.trimMemory()
        await store.load(page)
        let afterTrim = await client.requestURLs()
        XCTAssertEqual(afterTrim, requests, "同一会话中刷新失败后普通加载不能变成自动轮询")
    }

    @MainActor
    private func startConcurrentRefreshes(_ page: String, in store: IconStore) async -> [Task<Void, Never>] {
        let started = expectation(description: "所有 force 已进入共享加载")
        started.expectedFulfillmentCount = 3
        let refreshes = (0..<3).map { _ in
            Task { @MainActor in
                started.fulfill()
                await store.load(page, force: true)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        return refreshes
    }

    private func suspendedCache(for page: String) async throws -> SuspendedIconCache {
        let cache = IconCache(directory: directory)
        let pageURL = try XCTUnwrap(URL(string: page))
        let oldIcon = try XCTUnwrap(DecodedIcon.decode(png(width: 96, height: 96)))
        try await cache.save(oldIcon, originalPage: pageURL, finalPage: pageURL,
                             resource: pageURL.deletingLastPathComponent().appendingPathComponent("icon.png"))
        return SuspendedIconCache(cache: cache)
    }

    func testDecoderRejectsCorruptOversizeAndHugeDimensions() throws {
        XCTAssertNil(DecodedIcon.decode(Data("invalid".utf8)))
        XCTAssertNil(DecodedIcon.decode(Data(repeating: 0, count: IconRequestKind.image.byteLimit + 1)))
        XCTAssertNil(DecodedIcon.decode(try png(width: 8193, height: 1)))
        XCTAssertEqual(DecodedIcon.decode(try png(width: 512, height: 512))?.image.width, 256)
    }

    func testSVGDecoderRendersViewBoxAtCacheResolutionWithTransparency() throws {
        let data = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 50 25">
          <path fill="#ff0000" d="M0 0H25V25H0Z"/>
        </svg>
        """.utf8)
        let icon = try XCTUnwrap(DecodedIcon.decode(data))
        XCTAssertEqual(icon.image.width, 256)
        XCTAssertEqual(icon.image.height, 128)
        let bitmap = NSBitmapImageRep(cgImage: icon.image)
        let red = try XCTUnwrap(bitmap.colorAt(x: 32, y: 64)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(red.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(red.greenComponent, 0, accuracy: 0.01)
        XCTAssertEqual(red.alphaComponent, 1, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 224, y: 64)).alphaComponent, 0, accuracy: 0.01)
        let cached = try XCTUnwrap(DecodedIcon.decode(try XCTUnwrap(icon.pngData())))
        XCTAssertEqual(cached.image.width, 256)
        XCTAssertEqual(cached.image.height, 128)
    }

    func testSVGDecoderRejectsInvalidDocumentAndDimensions() {
        for source in [
            "<svg xmlns='http://www.w3.org/2000/svg'><path",
            "<html><body>Not an icon</body></html>",
            "<!DOCTYPE svg [<!ENTITY size '50'>]><svg xmlns='http://www.w3.org/2000/svg' width='&size;' height='50'/>",
            "<svg xmlns='http://www.w3.org/2000/svg' width='0' height='0'/>",
            "<svg xmlns='http://www.w3.org/2000/svg' width='8193' height='1'/>",
            "<svg xmlns='http://www.w3.org/2000/svg' width='8192' height='8192'/>"
        ] {
            XCTAssertNil(DecodedIcon.decode(Data(source.utf8)), source)
        }
    }

    @MainActor
    func testSVGWebsiteIconLoadsAndReusesPNGCacheOffline() async throws {
        let page = "https://example.com/usage"
        let icon = "https://cdn.example/favicon.svg"
        let client = FixtureIconClient([
            page: IconHTTPResponse(data: Data("<link rel='icon' type='image/x-icon' href='\(icon)'>".utf8), finalURL: URL(string: page)!),
            icon: IconHTTPResponse(data: Data("<svg xmlns='http://www.w3.org/2000/svg' width='50' height='50'><path fill='blue' d='M0 0H50V50H0Z'/></svg>".utf8), finalURL: URL(string: icon)!)
        ])
        let store = IconStore(cacheDirectory: directory, networkingEnabled: true, client: client)
        await store.load(page)
        XCTAssertEqual(store.image(for: page)?.size.width, 256)
        let requests = await client.requestURLs()
        XCTAssertEqual(requests, [page, icon])

        let offlineClient = FixtureIconClient()
        let offline = IconStore(cacheDirectory: directory, networkingEnabled: false, client: offlineClient)
        await offline.load(page)
        XCTAssertEqual(offline.image(for: page)?.size.width, 256)
        let offlineRequests = await offlineClient.requestURLs()
        XCTAssertTrue(offlineRequests.isEmpty)
    }

    private func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
