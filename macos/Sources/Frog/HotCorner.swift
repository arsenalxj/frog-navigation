import AppKit
import Combine

enum ScreenCorner: String, Codable, CaseIterable {
    case topLeft, bottomLeft, topRight, bottomRight
    var title: String {
        switch self {
        case .topLeft: return "左上"
        case .bottomLeft: return "左下"
        case .topRight: return "右上"
        case .bottomRight: return "右下"
        }
    }
    func contains(_ point: CGPoint, in frame: CGRect, size: CGFloat) -> Bool {
        guard frame.width > 0, frame.height > 0,
              point.x >= frame.minX, point.x <= frame.maxX, point.y >= frame.minY, point.y <= frame.maxY else { return false }
        let x = self == .topLeft || self == .bottomLeft ? point.x - frame.minX : frame.maxX - point.x
        let y = self == .bottomLeft || self == .bottomRight ? point.y - frame.minY : frame.maxY - point.y
        return x <= size && y <= size
    }
}

struct HotCornerConfiguration: Codable, Equatable {
    var enabled = true
    var corner = ScreenCorner.bottomLeft
}

struct HotCornerScreen: Equatable {
    let id: UInt32
    let frame: CGRect
}

struct HotCornerDetector {
    private var latchedScreens: Set<UInt32> = []
    mutating func reset(at point: CGPoint, screens: [HotCornerScreen], corner: ScreenCorner) {
        latchedScreens = Set(screens.filter { corner.contains(point, in: $0.frame, size: 8) }.map(\.id))
    }
    mutating func update(at point: CGPoint, screens: [HotCornerScreen], corner: ScreenCorner,
                         eligible: Bool, mouseButtonDown: Bool) -> HotCornerScreen? {
        latchedScreens = latchedScreens.filter { id in
            screens.contains { $0.id == id && corner.contains(point, in: $0.frame, size: 8) }
        }
        guard let screen = screens.first(where: { corner.contains(point, in: $0.frame, size: 2) }) else { return nil }
        guard latchedScreens.insert(screen.id).inserted else { return nil }
        // 被阻止的进入也记作已触碰，避免放开鼠标或收起窗口时原地唤起。
        return eligible && !mouseButtonDown ? screen : nil
    }
}

@MainActor
protocol HotCornerEventMonitoring: AnyObject {
    var screens: [HotCornerScreen] { get }
    var mouseLocation: CGPoint { get }
    var suspended: Bool { get }
    func start(sample: @escaping (CGPoint, Bool) -> Void, reset: @escaping () -> Void) throws
    func stop()
}

@MainActor
final class NativeHotCornerMonitor: HotCornerEventMonitoring {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var displayObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var suspensions: Set<String> = []
    var suspended: Bool { !suspensions.isEmpty }
    var mouseLocation: CGPoint { NSEvent.mouseLocation }
    var screens: [HotCornerScreen] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return HotCornerScreen(id: number.uint32Value, frame: screen.frame)
        }
    }

    func start(sample: @escaping (CGPoint, Bool) -> Void, reset: @escaping () -> Void) throws {
        stop()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                          .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp]
        let handle: (NSEvent) -> Void = { event in
            let draggingOrDown: Set<NSEvent.EventType> = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                                         .leftMouseDown, .rightMouseDown, .otherMouseDown]
            sample(NSEvent.mouseLocation, NSEvent.pressedMouseButtons != 0 || draggingOrDown.contains(event.type))
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handle)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in handle(event); return event }
        guard globalMonitor != nil, localMonitor != nil else {
            stop()
            throw MonitorError.unavailable
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { reset() }
        }
        let notifications: [(Notification.Name, String, Bool)] = [
            (NSWorkspace.willSleepNotification, "sleep", true), (NSWorkspace.didWakeNotification, "sleep", false),
            (NSWorkspace.screensDidSleepNotification, "display", true), (NSWorkspace.screensDidWakeNotification, "display", false),
            (NSWorkspace.sessionDidResignActiveNotification, "session", true), (NSWorkspace.sessionDidBecomeActiveNotification, "session", false)
        ]
        for (name, reason, paused) in notifications {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if paused { self.suspensions.insert(reason) } else { self.suspensions.remove(reason) }
                    reset()
                }
            })
        }
    }
    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver); self.displayObserver = nil }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll(); suspensions.removeAll()
    }
    private enum MonitorError: LocalizedError {
        case unavailable
        var errorDescription: String? { "系统未能启用鼠标监听，请重试。" }
    }
}

@MainActor
final class HotCornerController: ObservableObject {
    static let preferencesKey = "screenHotCorner"
    @Published private(set) var configuration: HotCornerConfiguration
    @Published private(set) var monitoring = false
    @Published private(set) var error: String?
    var canTrigger: () -> Bool = { false }
    var onTrigger: ((HotCornerScreen) -> Void)?
    private let source: HotCornerEventMonitoring
    private let defaults: UserDefaults?
    private var detector = HotCornerDetector()
    private var screens: [HotCornerScreen] = []
    private var started = false
    private var generation = 0

    init(source: HotCornerEventMonitoring, defaults: UserDefaults? = .standard) {
        self.source = source; self.defaults = defaults
        configuration = defaults?.data(forKey: Self.preferencesKey)
            .flatMap { try? JSONDecoder().decode(HotCornerConfiguration.self, from: $0) } ?? HotCornerConfiguration()
    }
    func start() {
        guard !started else { return }
        started = true
        configureMonitoring()
    }
    func stop() {
        started = false; generation &+= 1
        source.stop(); monitoring = false
    }
    func setEnabled(_ enabled: Bool) {
        configuration.enabled = enabled
        saveAndConfigure()
    }
    func setCorner(_ corner: ScreenCorner) {
        configuration.corner = corner
        saveAndConfigure()
    }
    func retry() { configureMonitoring() }

    private func saveAndConfigure() {
        if let data = try? JSONEncoder().encode(configuration) { defaults?.set(data, forKey: Self.preferencesKey) }
        configureMonitoring()
    }
    private func configureMonitoring() {
        generation &+= 1
        source.stop(); monitoring = false; error = nil
        guard started, configuration.enabled else { return }
        resetPosition()
        let current = generation
        do {
            try source.start(sample: { [weak self] point, buttonDown in
                guard let self, self.generation == current, self.monitoring else { return }
                if let screen = self.detector.update(at: point, screens: self.screens, corner: self.configuration.corner,
                                                     eligible: !self.source.suspended && self.canTrigger(), mouseButtonDown: buttonDown) {
                    self.onTrigger?(screen)
                }
            }, reset: { [weak self] in
                guard let self, self.generation == current else { return }
                self.resetPosition()
            })
            monitoring = true
        } catch {
            source.stop()
            self.error = error.localizedDescription
        }
    }
    private func resetPosition() {
        screens = source.screens
        detector.reset(at: source.mouseLocation, screens: screens, corner: configuration.corner)
    }
}
