import AppKit
import Carbon

/// 纯按键状态：被消费的按下、重复和释放成对处理；资格变化不触发第二次导航。
struct FinderJumpKeyGate {
    enum Decision: Equatable { case pass, consume, trigger }
    private(set) var held = false

    mutating func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags,
                         isRepeat: Bool, injected: Bool, eligible: Bool) -> Decision {
        guard !injected, keyCode == Int64(kVK_ANSI_G) else { return .pass }
        if type == .keyUp {
            guard held else { return .pass }
            held = false
            return .consume
        }
        guard type == .keyDown else { return .pass }
        if held { return .consume }
        let modifiers = flags.intersection([.maskControl, .maskCommand, .maskAlternate, .maskShift, .maskSecondaryFn])
        guard eligible, !isRepeat, modifiers == .maskControl else { return .pass }
        held = true
        return .trigger
    }
}

@MainActor
protocol FinderJumpHotKeyMonitoring: AnyObject {
    var onTrigger: (() -> Void)? { get set }
    var onFailure: (() -> Void)? { get set }
    func start() throws
    func setTargetPID(_ pid: Int32?, sessionID: String?)
    func stop()
}

@MainActor
final class FinderJumpHotKey: FinderJumpHotKeyMonitoring {
    static let shortcut = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(controlKey))
    static let injectedEventTag: Int64 = 0x4152504A
    var onTrigger: (() -> Void)?
    var onFailure: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var gate = FinderJumpKeyGate()
    private var targetPID: Int32?
    private var sessionID: String?
    private var generation = 0
    private var sessionGeneration = 0
    private var stopping = false

    func start() throws {
        stopping = false
        guard tap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                Unmanaged<FinderJumpHotKey>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            }
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            throw MonitoringError.unavailable
        }
        tap = newTap; source = newSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
    }

    func setTargetPID(_ pid: Int32?, sessionID: String?) {
        if targetPID != pid || self.sessionID != sessionID { sessionGeneration &+= 1 }
        targetPID = pid; self.sessionID = sessionID
    }

    func stop() {
        generation &+= 1
        targetPID = nil; sessionID = nil
        if gate.held, tap != nil {
            // 关闭立刻停止新触发，仅短暂收尾已经消费的按键对。
            stopping = true
            let current = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.stopping, self.generation == current else { return }
                self.tearDown()
            }
        } else { tearDown() }
    }

    private func tearDown() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; gate = FinderJumpKeyGate(); stopping = false
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            targetPID = nil; sessionID = nil
            generation &+= 1
            tearDown()
            let current = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current else { return }
                self.onFailure?()
            }
            return Unmanaged.passUnretained(event)
        }
        // 不在 tap 内访问辅助功能、磁盘或 Apple Events。前台 PID 是额外的切换竞态保护。
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let injected = event.getIntegerValueField(.eventSourceUserData) == Self.injectedEventTag
        let eligible = keyCode == Int64(kVK_ANSI_G) && !injected && !stopping && targetPID != nil &&
            targetPID == NSWorkspace.shared.frontmostApplication?.processIdentifier
        let decision = gate.handle(type: type, keyCode: keyCode,
                                   flags: event.flags, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                   injected: injected,
                                   eligible: eligible)
        if decision == .trigger {
            let current = generation
            let session = sessionGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current, self.sessionGeneration == session, self.targetPID != nil else { return }
                self.onTrigger?()
            }
        }
        if stopping && !gate.held { tearDown() }
        return decision == .pass ? Unmanaged.passUnretained(event) : nil
    }

    private enum MonitoringError: LocalizedError {
        case unavailable
        var errorDescription: String? { "无法启用 ⌃G，请检查键盘监听权限后重试。目录入口仍可点击。" }
    }

    deinit {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}
