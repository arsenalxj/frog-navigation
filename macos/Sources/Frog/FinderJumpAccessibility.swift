import AppKit
import ApplicationServices

struct FinderJumpTarget: Equatable, Sendable {
    let hostPID: Int32
    let elementPID: Int32
    /// 辅助功能使用主显示器左上原点，浮条负责转换到 AppKit 坐标。
    let frame: CGRect
    let identity: String
}

@MainActor
protocol FinderJumpBackend: AnyObject {
    var onChange: (() -> Void)? { get set }
    var target: FinderJumpTarget? { get }
    var location: URL? { get }
    func start()
    func stop()
    func refresh()
    func navigate() async throws
}

struct FinderJumpAXDescription: Equatable {
    let role: String
    let identifier: String
}

/// 系统面板的结构指纹；标题、单独的 AXSheet、普通确认对话框都不足以匹配。
enum FinderJumpPanelRules {
    static func isFilePanel(root: FinderJumpAXDescription, descendants: [FinderJumpAXDescription]) -> Bool {
        guard ["AXWindow", "AXSheet"].contains(root.role),
              ["open-panel", "save-panel"].contains(root.identifier) else { return false }
        let identifiers = Set(descendants.map(\.identifier))
        let hasBrowser = descendants.contains { ["AXBrowser", "AXOutline", "AXTable"].contains($0.role) }
        let hasNameField = descendants.contains { $0.role == "AXTextField" && $0.identifier == "saveAsNameTextField" }
        return identifiers.contains("where popup") && identifiers.contains("OKButton")
            && identifiers.contains("CancelButton") && (hasBrowser || hasNameField)
    }
}

/// 跨线程生命周期闸门：关闭设置和切换应用可立即使后台导航失效。
final class FinderJumpSessionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var active = false
    private var foreground: pid_t = 0
    private var foregroundRevision: UInt64 = 0
    var navigationRevision: UInt64 { lock.lock(); defer { lock.unlock() }; return foregroundRevision }
    func begin(frontPID: pid_t) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1; active = true; foreground = frontPID; return generation
    }
    func stop() { lock.lock(); active = false; generation &+= 1; lock.unlock() }
    func setForeground(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        if foreground != pid { foregroundRevision &+= 1; foreground = pid }
    }
    func invalidateNavigation() { lock.lock(); foregroundRevision &+= 1; lock.unlock() }
    func accepts(_ token: UInt64, hostPID: pid_t? = nil, navigationRevision: UInt64? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active && generation == token && (hostPID == nil || hostPID == foreground)
            && (navigationRevision == nil || navigationRevision == foregroundRevision)
    }
}

/// 所有同步 AX 与 Apple Events 调用均在单独串行队列上执行。
@MainActor
final class NativeFinderJumpBackend: FinderJumpBackend {
    var onChange: (() -> Void)?
    private(set) var target: FinderJumpTarget?
    private(set) var location: URL?
    private let gate = FinderJumpSessionGate()
    private let worker: FinderJumpWorking
    private let observeSystemEvents: Bool
    private let frontmostPID: () -> pid_t
    private var token: UInt64 = 0
    private var active = false
    private var subscriptions: [NSObjectProtocol] = []
    private var delayedRefresh: Task<Void, Never>?
    private var refreshing = false
    private var refreshAgain = false
    private var readFinder = false
    private var refreshRevision: UInt64 = 0

    init(worker: FinderJumpWorking = FinderJumpWorker(), observeSystemEvents: Bool = true,
         frontmostPID: @escaping () -> pid_t = { NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }) {
        self.worker = worker; self.observeSystemEvents = observeSystemEvents; self.frontmostPID = frontmostPID
    }

    func start() {
        guard !active else { refresh(); return }
        active = true
        token = gate.begin(frontPID: frontmostPID())
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] where observeSystemEvents {
            subscriptions.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.gate.setForeground(self.frontmostPID())
                    if notification.name == NSWorkspace.activeSpaceDidChangeNotification { self.gate.invalidateNavigation() }
                    self.target = nil; self.onChange?()
                    self.scheduleRefresh(readFinder: notification.name != NSWorkspace.activeSpaceDidChangeNotification)
                    // 仅由外部事件触发的单次延后检查，等待远程面板创建；没有后台计时轮询。
                    self.delayedRefresh?.cancel()
                    self.delayedRefresh = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(180))
                        guard !Task.isCancelled else { return }
                        self?.scheduleRefresh(readFinder: false)
                    }
                }
            })
        }
        scheduleRefresh(readFinder: true)
    }

    func stop() {
        guard active else { return }
        active = false; gate.stop(); delayedRefresh?.cancel(); delayedRefresh = nil
        refreshing = false; refreshAgain = false; readFinder = false
        subscriptions.forEach(NSWorkspace.shared.notificationCenter.removeObserver); subscriptions.removeAll()
        target = nil; location = nil; onChange?()
        worker.stop()
    }

    func refresh() {
        target = nil; onChange?()
        scheduleRefresh(readFinder: true)
    }

    private func scheduleRefresh(readFinder: Bool) {
        guard active else { return }
        // 新事件使在途快照失效；合并请求也必须推进代次。
        refreshRevision &+= 1
        self.readFinder = self.readFinder || readFinder
        if refreshing { refreshAgain = true; return }
        refreshing = true
        let readsFinder = self.readFinder; self.readFinder = false
        let currentToken = token
        let currentRevision = refreshRevision
        let front = frontmostPID()
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
        gate.setForeground(front)
        // 自身 AX 调用会直接进入 SwiftUI，后台遍历可与主线程互锁；仅扫描其他应用。
        let panelHostPID: pid_t = front == getpid() ? 0 : front
        worker.refresh(frontPID: panelHostPID, finderPID: finder, readsFinder: readsFinder, token: currentToken, gate: gate,
            event: { [weak self] isFinder in
                Task { @MainActor in
                    guard let self, self.active, self.token == currentToken else { return }
                    self.target = nil; self.onChange?()
                    self.scheduleRefresh(readFinder: isFinder)
                }
            }, completion: { [weak self] state in
                Task { @MainActor in
                    // 旧会话的完成回调也不能修改新会话的扫描调度状态。
                    guard let self, self.active, self.token == currentToken else { return }
                    self.refreshing = false
                    if self.refreshRevision == currentRevision, self.gate.accepts(currentToken, hostPID: front) {
                        if self.target != state.target || self.location != state.location {
                            self.target = state.target; self.location = state.location; self.onChange?()
                        }
                    }
                    if self.active, self.refreshAgain { self.refreshAgain = false; self.scheduleRefresh(readFinder: false) }
                }
            })
    }

    func navigate() async throws {
        guard active, let target, let location else { throw FinderJumpNavigationError.unavailable }
        let operation = FinderJumpNavigationCancellation()
        defer { scheduleRefresh(readFinder: false) }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                worker.navigate(target: target, location: location, token: token, gate: gate, cancellation: operation) {
                    continuation.resume(with: $0)
                }
            }
        }, onCancel: { operation.cancel() })
    }
}

struct FinderJumpPanelSession {
    var target: FinderJumpTarget
    let application: AXUIElement
    let window: AXUIElement
    let panel: AXUIElement
    let nodes: [AXUIElement]
}

struct FinderJumpWorkerState {
    let target: FinderJumpTarget?
    let location: URL?
}

protocol FinderJumpWorking: AnyObject {
    func stop()
    func refresh(frontPID: pid_t, finderPID: pid_t?, readsFinder: Bool, token: UInt64, gate: FinderJumpSessionGate,
                 event: @escaping (Bool) -> Void, completion: @escaping (FinderJumpWorkerState) -> Void)
    func navigate(target: FinderJumpTarget, location: URL, token: UInt64, gate: FinderJumpSessionGate,
                  cancellation: FinderJumpNavigationCancellation, completion: @escaping (Result<Void, Error>) -> Void)
}

final class FinderJumpWorker: FinderJumpWorking, @unchecked Sendable {
    let queue = DispatchQueue(label: "cn.arsenalxj.Frog.finder-jump", qos: .userInitiated)
    private var observers: [pid_t: FinderJumpAXObservation] = [:]
    private var cache = FinderJumpLocationCache()
    private var directoryWatch: FinderJumpDirectoryWatch?
    private var session: FinderJumpPanelSession?

    func stop() {
        queue.async { [self] in
            observers.removeAll(); directoryWatch?.stop(); directoryWatch = nil; session = nil
            // 设置关闭后保留本次运行内的最后目录，再开启时重新验证。
        }
    }

    func refresh(frontPID: pid_t, finderPID: pid_t?, readsFinder: Bool, token: UInt64, gate: FinderJumpSessionGate,
                 event: @escaping (Bool) -> Void, completion: @escaping (FinderJumpWorkerState) -> Void) {
        queue.async { [self] in
            guard gate.accepts(token) else { completion(.init(target: nil, location: nil)); return }
            if readsFinder, let finderPID { cache.accept(FinderJumpFinderReader.currentDirectory(pid: finderPID)) }
            if directoryWatch == nil { directoryWatch = FinderJumpDirectoryWatch(queue: queue) { event(false) } }
            directoryWatch?.watch(cache.lastDirectory)
            var nextSession = AXIsProcessTrusted() ? FinderJumpAX.findPanel(hostPID: frontPID) : nil
            if let previous = session, let next = nextSession,
               CFEqual(previous.window, next.window), CFEqual(previous.panel, next.panel) {
                nextSession?.target = .init(hostPID: next.target.hostPID, elementPID: next.target.elementPID,
                    frame: next.target.frame, identity: previous.target.identity)
            }
            session = nextSession
            let pids = Set([frontPID, finderPID, session?.target.elementPID].compactMap { $0 }.filter { $0 > 0 })
            for pid in observers.keys where !pids.contains(pid) { observers.removeValue(forKey: pid) }
            for pid in pids {
                if observers[pid] == nil {
                    observers[pid] = FinderJumpAXObservation(pid: pid) { event(pid == finderPID) }
                }
                var watched = [AXUIElementCreateApplication(pid)]
                if let session, [session.target.hostPID, session.target.elementPID].contains(pid) {
                    watched += [session.window, session.panel]
                    watched += session.nodes.filter {
                        ["where popup", "Search", "View Options"].contains(FinderJumpAX.string($0, "AXIdentifier"))
                    }
                } else if pid == finderPID {
                    let app = AXUIElementCreateApplication(pid)
                    if let window = FinderJumpAX.element(app, "AXFocusedWindow") ?? FinderJumpAX.element(app, "AXMainWindow") { watched.append(window) }
                }
                observers[pid]?.watch(watched)
            }
            guard gate.accepts(token, hostPID: frontPID) else { completion(.init(target: nil, location: cache.validDirectory())); return }
            completion(.init(target: session?.target, location: cache.validDirectory()))
        }
    }

    func navigate(target: FinderJumpTarget, location: URL, token: UInt64, gate: FinderJumpSessionGate,
                  cancellation: FinderJumpNavigationCancellation, completion: @escaping (Result<Void, Error>) -> Void) {
        let foregroundRevision = gate.navigationRevision
        queue.async { [self] in
            do {
                guard let session, session.target.identity == target.identity else { throw FinderJumpNavigationError.changedFocus }
                try FinderJumpNavigation.run(session: session, directory: location, isCurrent: {
                    gate.accepts(token, hostPID: target.hostPID, navigationRevision: foregroundRevision) && !cancellation.isCancelled
                })
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }
}

enum FinderJumpAX {
    static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.08)
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
    static func string(_ element: AXUIElement, _ name: String) -> String { value(element, name) as? String ?? "" }
    static func element(_ source: AXUIElement, _ name: String) -> AXUIElement? {
        guard let raw = value(source, name), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }
    static func children(_ source: AXUIElement) -> [AXUIElement] {
        // 使用范围读取，避免一个大目录让桥接层返回所有文件行。
        var raw: CFArray?
        guard AXUIElementCopyAttributeValues(source, "AXChildren" as CFString, 0, 80, &raw) == .success else { return [] }
        return raw as? [AXUIElement] ?? []
    }
    static func pid(_ source: AXUIElement) -> pid_t { var pid: pid_t = 0; AXUIElementGetPid(source, &pid); return pid }
    static func frame(_ source: AXUIElement) -> CGRect? {
        guard let p = value(source, "AXPosition"), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = value(source, "AXSize"), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }
    static func walk(_ root: AXUIElement, includeRows: Bool = false, limit: Int = 180, timeout: TimeInterval = 0.8) -> [AXUIElement] {
        let deadline = Date().addingTimeInterval(timeout)
        var result: [AXUIElement] = []; var pending: [(AXUIElement, Int)] = [(root, 0)]; var index = 0
        while index < pending.count, result.count < limit, Date() < deadline {
            let (node, depth) = pending[index]; index += 1
            if result.contains(where: { CFEqual($0, node) }) { continue }
            result.append(node)
            guard depth < 12 else { continue }
            let role = string(node, "AXRole")
            if !includeRows, ["AXRow", "AXBrowser", "AXOutline", "AXTable", "AXList", "AXMenuBar"].contains(role) { continue }
            pending += children(node).map { ($0, depth + 1) }
        }
        return result
    }
    static func describe(_ source: AXUIElement) -> FinderJumpAXDescription {
        .init(role: string(source, "AXRole"), identifier: string(source, "AXIdentifier"))
    }
    static func focusedWindow(_ application: AXUIElement) -> AXUIElement? {
        guard let focused = element(application, "AXFocusedWindow") else { return nil }
        // XPC 内容获得焦点后，同一宿主的 AXFocusedWindow 可从 AXWindow 变为 AXSheet。
        // 统一比较其宿主窗口，面板身份另外以 CFEqual 校验。
        if string(focused, "AXRole") == "AXSheet" { return element(focused, "AXWindow") }
        return focused
    }
    static func findPanel(hostPID: pid_t) -> FinderJumpPanelSession? {
        guard hostPID > 0 else { return nil }
        let application = AXUIElementCreateApplication(hostPID)
        guard let window = focusedWindow(application),
              value(window, "AXMinimized") as? Bool != true else { return nil }
        // 系统焦点在部分 XPC 桥接应用上不可读，回退到宿主焦点；再从文件面板后代收集远程观察进程。
        let focused = element(AXUIElementCreateSystemWide(), "AXFocusedUIElement") ?? element(application, "AXFocusedUIElement")
        let deadline = Date().addingTimeInterval(1.2)
        let nodes = walk(window)
        for panel in nodes.reversed() {
            guard Date() < deadline else { return nil }
            let description = describe(panel)
            guard ["open-panel", "save-panel"].contains(description.identifier) else { continue }
            let descendants = walk(panel)
            var descriptions: [FinderJumpAXDescription] = []
            for node in descendants {
                guard Date() < deadline else { return nil }
                descriptions.append(describe(node))
            }
            guard FinderJumpPanelRules.isFilePanel(root: description, descendants: descriptions),
                  !descriptions.contains(where: { $0.identifier == "GoToWindow" }),
                  let frame = frame(panel), Date() < deadline else { continue }
            // 其他警告或覆盖子面板出现时不接管快捷键。
            guard !zip(descendants, descriptions).contains(where: { !CFEqual($0.0, panel) && $0.1.role == "AXSheet" }) else { continue }
            let remotePID: pid_t = descendants.map { FinderJumpAX.pid($0) }.first { $0 > 0 && $0 != hostPID }
                ?? focused.map { FinderJumpAX.pid($0) } ?? FinderJumpAX.pid(panel)
            let identity = UUID().uuidString
            return .init(target: .init(hostPID: hostPID, elementPID: remotePID, frame: frame, identity: identity),
                         application: application, window: window, panel: panel, nodes: descendants)
        }
        return nil
    }
    static func perform(_ action: String, on element: AXUIElement) -> AXError {
        // 窗口展开等动作可能等待系统动画；读属性的短超时不适合动作回执。
        AXUIElementSetMessagingTimeout(element, 1)
        return AXUIElementPerformAction(element, action as CFString)
    }
    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        return AXUIElementCopyActionNames(element, &names) == .success ? names as? [String] ?? [] : []
    }
}

private final class FinderJumpAXCallback {
    let onEvent: () -> Void
    init(_ onEvent: @escaping () -> Void) { self.onEvent = onEvent }
}

private final class FinderJumpAXObservation {
    let observer: AXObserver
    private let callback: UnsafeMutableRawPointer
    private var registrations: [(AXUIElement, String)] = []
    init?(pid: pid_t, onEvent: @escaping () -> Void) {
        var created: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, pointer in
            guard let pointer else { return }
            Unmanaged<FinderJumpAXCallback>.fromOpaque(pointer).takeUnretainedValue().onEvent()
        }, &created) == .success, let created else { return nil }
        observer = created
        callback = Unmanaged.passRetained(FinderJumpAXCallback(onEvent)).toOpaque()
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
    func watch(_ elements: [AXUIElement]) {
        let deadline = Date().addingTimeInterval(0.6)
        let notifications = ["AXFocusedWindowChanged", "AXFocusedUIElementChanged", "AXWindowCreated", "AXSheetCreated",
                             "AXWindowMoved", "AXWindowResized", "AXUIElementDestroyed", "AXValueChanged",
                             "AXSelectedChildrenChanged", "AXTitleChanged", "AXLayoutChanged"]
        for (element, name) in registrations where !elements.contains(where: { CFEqual($0, element) }) {
            AXObserverRemoveNotification(observer, element, name as CFString)
        }
        registrations.removeAll { item in !elements.contains(where: { CFEqual($0, item.0) }) }
        for element in elements {
            AXUIElementSetMessagingTimeout(element, 0.08)
            for name in notifications where !registrations.contains(where: { CFEqual($0.0, element) && $0.1 == name }) {
                guard Date() < deadline else { return }
                if AXObserverAddNotification(observer, element, name as CFString, callback) == .success {
                    registrations.append((element, name))
                }
            }
        }
    }
    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        for (element, name) in registrations { AXObserverRemoveNotification(observer, element, name as CFString) }
        // 移除 source 后，先让主线程上已经进入的回调完成，再释放不可变的 refcon。
        let pointer = callback
        DispatchQueue.main.async { Unmanaged<FinderJumpAXCallback>.fromOpaque(pointer).release() }
    }
}
