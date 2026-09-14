import Foundation

enum IconRequestKind: Sendable {
    case html, image
    var byteLimit: Int { self == .html ? 512 * 1024 : 4 * 1024 * 1024 }
}

struct IconHTTPResponse: Sendable {
    let data: Data
    let finalURL: URL
}

enum IconFetchError: Error, Equatable {
    case invalidURL, invalidResponse, unsupportedContent, responseTooLarge, tooManyRedirects, invalidImage
}

protocol IconHTTPFetching: Sendable {
    func fetch(_ url: URL, kind: IconRequestKind) async throws -> IconHTTPResponse
}

/// 所有抓取共享四个网络席位；等待席位及请求本身都不会阻塞主线程。
actor BoundedHTTPClient: IconHTTPFetching {
    private var active = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    func fetch(_ url: URL, kind: IconRequestKind) async throws -> IconHTTPResponse {
        guard IconURL.valid(url.absoluteString) != nil else { throw IconFetchError.invalidURL }
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        let connection = IconHTTPConnection(configuration: configuration, kind: kind)
        return try await withTaskCancellationHandler {
            try await connection.run(url)
        } onCancel: {
            connection.cancel()
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if active < 4 { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().continuation.resume() }
    }
}

private final class IconHTTPConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private let kind: IconRequestKind
    private var session: URLSession?
    private var continuation: CheckedContinuation<IconHTTPResponse, Error>?
    private var cancelled = false
    // 以下字段只由串行 delegateQueue 访问。
    private var data = Data()
    private var finalURL: URL?
    private var redirects = 0

    init(configuration: URLSessionConfiguration, kind: IconRequestKind) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.kind = kind
        super.init()
    }

    func run(_ url: URL) async throws -> IconHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 15
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.httpShouldSetCookies = false
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .utility
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.setValue("Frog/1.0 (macOS; website icon preview)", forHTTPHeaderField: "User-Agent")
            request.setValue(kind == .html ? "text/html,application/xhtml+xml" : "image/*,*/*;q=0.1", forHTTPHeaderField: "Accept")
            let task = session.dataTask(with: request)
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<IconHTTPResponse, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let activeSession = session
        session = nil
        lock.unlock()
        activeSession?.invalidateAndCancel()
        pending?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 5 else {
            completionHandler(nil)
            finish(.failure(IconFetchError.tooManyRedirects))
            return
        }
        guard let url = request.url, IconURL.valid(url.absoluteString) != nil else {
            completionHandler(nil)
            finish(.failure(IconFetchError.invalidURL))
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let url = http.url,
              IconURL.valid(url.absoluteString) != nil else {
            completionHandler(.cancel)
            finish(.failure(IconFetchError.invalidResponse))
            return
        }
        let mime = (http.mimeType ?? "").lowercased()
        let accepted = kind == .html
            ? ["text/html", "application/xhtml+xml"].contains(mime)
            : mime.hasPrefix("image/") || ["application/octet-stream", "binary/octet-stream", ""].contains(mime)
        guard accepted else {
            completionHandler(.cancel)
            finish(.failure(IconFetchError.unsupportedContent))
            return
        }
        guard response.expectedContentLength <= Int64(kind.byteLimit) else {
            completionHandler(.cancel)
            finish(.failure(IconFetchError.responseTooLarge))
            return
        }
        finalURL = url
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard chunk.count <= kind.byteLimit - data.count else {
            finish(.failure(IconFetchError.responseTooLarge))
            return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        else if let finalURL { finish(.success(IconHTTPResponse(data: data, finalURL: finalURL))) }
        else { finish(.failure(IconFetchError.invalidResponse)) }
    }
}
