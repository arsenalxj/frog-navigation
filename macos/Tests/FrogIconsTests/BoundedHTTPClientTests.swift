import Foundation
import XCTest
@testable import FrogIcons

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    static var responder: ((URLRequest) -> (headers: [String: String], chunks: [Data], status: Int))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let result = Self.responder?(request), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: result.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if (300...399).contains(result.status), let location = result.headers["Location"], let redirect = URL(string: location, relativeTo: url) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in result.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RequestTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var active = Set<ObjectIdentifier>()
    private var maximum = 0
    private var started = 0
    private var completed = 0
    let delay: TimeInterval
    let starts: XCTestExpectation?

    init(delay: TimeInterval, starts: XCTestExpectation? = nil) { self.delay = delay; self.starts = starts }
    func start(_ object: AnyObject) {
        lock.lock()
        active.insert(ObjectIdentifier(object))
        maximum = max(maximum, active.count)
        started += 1
        lock.unlock()
        starts?.fulfill()
    }
    func stop(_ object: AnyObject, completed: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let existed = active.remove(ObjectIdentifier(object)) != nil
        if existed, completed { self.completed += 1 }
        return existed
    }
    func snapshot() -> (maximum: Int, started: Int, completed: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (maximum, started, completed)
    }
}

private final class TrackingURLProtocol: URLProtocol, @unchecked Sendable {
    static var tracker = RequestTracker(delay: 0.05)
    private var currentTracker: RequestTracker?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let tracker = Self.tracker
        currentTracker = tracker
        tracker.start(self)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + tracker.delay) { [weak self] in
            guard let self, tracker.stop(self, completed: true), let url = self.request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"]) else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data("hello".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { _ = currentTracker?.stop(self) }
}

final class BoundedHTTPClientTests: XCTestCase {
    override func tearDown() { FixtureURLProtocol.responder = nil }

    func testRejectsOversizedContentLengthBeforeBody() async {
        FixtureURLProtocol.responder = { _ in (["Content-Type": "image/png", "Content-Length": "5000000"], [], 200) }
        await assertFetchFails(.responseTooLarge, kind: .image)
    }

    func testRejectsStreamThatGrowsPastLimitWithoutContentLength() async {
        FixtureURLProtocol.responder = { _ in
            (["Content-Type": "text/html"], [Data(repeating: 65, count: 400_000), Data(repeating: 66, count: 200_000)], 200)
        }
        await assertFetchFails(.responseTooLarge, kind: .html)
    }

    func testRejectsHTTPErrorAndIncompatibleMIME() async {
        FixtureURLProtocol.responder = { _ in (["Content-Type": "image/png"], [], 404) }
        await assertFetchFails(.invalidResponse, kind: .image)
        FixtureURLProtocol.responder = { _ in (["Content-Type": "text/html"], [Data("<html>error</html>".utf8)], 200) }
        await assertFetchFails(.unsupportedContent, kind: .image)
    }

    func testCollectsBoundedChunksAndPreservesURL() async throws {
        FixtureURLProtocol.responder = { _ in (["Content-Type": "text/html"], [Data("hello ".utf8), Data("world".utf8)], 200) }
        let response = try await makeClient().fetch(URL(string: "https://example.com/test")!, kind: .html)
        XCTAssertEqual(String(data: response.data, encoding: .utf8), "hello world")
        XCTAssertEqual(response.finalURL.absoluteString, "https://example.com/test")
    }

    func testRejectsNonHTTPURLBeforeOpeningConnection() async {
        do {
            _ = try await makeClient().fetch(URL(string: "file:///tmp/icon.png")!, kind: .image)
            XCTFail("应拒绝非 HTTP 地址")
        } catch { XCTAssertEqual(error as? IconFetchError, .invalidURL) }
    }

    func testStopsAfterFiveRedirectsAndPreservesSuccessfulFinalURL() async throws {
        FixtureURLProtocol.responder = { request in
            let count = Int(request.url!.lastPathComponent) ?? 0
            return (["Location": "https://example.com/\(count + 1)"], [], 302)
        }
        await assertFetchFails(.tooManyRedirects, kind: .html)
        FixtureURLProtocol.responder = { request in
            if request.url!.path == "/test" { return (["Location": "https://example.com/final"], [], 302) }
            return (["Content-Type": "text/html"], [Data("ok".utf8)], 200)
        }
        let response = try await makeClient().fetch(URL(string: "https://example.com/test")!, kind: .html)
        XCTAssertEqual(response.finalURL.absoluteString, "https://example.com/final")
    }

    func testLimitsConcurrentConnectionsToFour() async throws {
        let tracker = RequestTracker(delay: 0.03)
        TrackingURLProtocol.tracker = tracker
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrackingURLProtocol.self]
        let client = BoundedHTTPClient(configuration: configuration)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for number in 0..<12 {
                group.addTask { _ = try await client.fetch(URL(string: "https://example.com/\(number)")!, kind: .html) }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(tracker.snapshot().maximum, 4)
        XCTAssertEqual(tracker.snapshot().started, 12)
    }

    func testCancelsQueuedRequestWithoutWaitingForActiveConnections() async throws {
        let started = expectation(description: "四个连接已占用")
        started.expectedFulfillmentCount = 4
        let tracker = RequestTracker(delay: 1, starts: started)
        TrackingURLProtocol.tracker = tracker
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrackingURLProtocol.self]
        let client = BoundedHTTPClient(configuration: configuration)
        let running = (0..<4).map { number in
            Task { try await client.fetch(URL(string: "https://example.com/\(number)")!, kind: .html) }
        }
        await fulfillment(of: [started], timeout: 2)
        let queued = Task { try await client.fetch(URL(string: "https://example.com/queued")!, kind: .html) }
        for _ in 0..<10 { await Task.yield() }
        queued.cancel()
        do { _ = try await queued.value; XCTFail("应取消排队请求") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(tracker.snapshot().started, 4)
        XCTAssertEqual(tracker.snapshot().completed, 0)
        for task in running { task.cancel() }
        for task in running { _ = await task.result }
    }

    private func makeClient() -> BoundedHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return BoundedHTTPClient(configuration: configuration)
    }

    private func assertFetchFails(_ expected: IconFetchError, kind: IconRequestKind,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await makeClient().fetch(URL(string: "https://example.com/test")!, kind: kind)
            XCTFail("应拒绝响应", file: file, line: line)
        } catch { XCTAssertEqual(error as? IconFetchError, expected, file: file, line: line) }
    }
}
