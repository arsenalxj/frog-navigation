import AppKit
import ApplicationServices
import Carbon

enum FinderJumpPermission: String, CaseIterable {
    case accessibility, finderAutomation, postEvents, listenEvents

    var buttonTitle: String {
        switch self {
        case .accessibility: return "允许辅助功能"
        case .finderAutomation: return "允许读取 Finder 目录"
        case .postEvents: return "允许键盘控制"
        case .listenEvents: return "允许键盘监听"
        }
    }
}

struct FinderJumpPermissionState: Equatable {
    var accessibility = false
    var finderAutomation = false
    var postEvents = false
    var listenEvents = false
    var finderAutomationError: String?

    var canNavigate: Bool { accessibility && finderAutomation && postEvents }
    var missing: [FinderJumpPermission] {
        FinderJumpPermission.allCases.filter {
            switch $0 {
            case .accessibility: return !accessibility
            case .finderAutomation: return !finderAutomation
            case .postEvents: return !postEvents
            case .listenEvents: return !listenEvents
            }
        }
    }
}

@MainActor
protocol FinderJumpPermissionChecking: AnyObject {
    func check() async -> FinderJumpPermissionState
    func request(_ permission: FinderJumpPermission) async
}

@MainActor
final class NativeFinderJumpPermissions: FinderJumpPermissionChecking {
    private let automation = FinderJumpAutomationAuthorizer()

    func check() async -> FinderJumpPermissionState {
        var state = FinderJumpPermissionState(accessibility: AXIsProcessTrusted(),
                                             postEvents: CGPreflightPostEventAccess(), listenEvents: CGPreflightListenEventAccess())
        guard state.accessibility else { return state }
        let status = await automation.finderPermission(prompt: false)
        state.accessibility = AXIsProcessTrusted()
        state.finderAutomation = status == noErr
        if status == errAETimeout {
            state.finderAutomationError = "检查 Finder 授权超时，请确认 Finder 已打开；仍未恢复时重启青蛙导航。"
        } else if ![noErr, OSStatus(errAEEventNotPermitted), OSStatus(errAEEventWouldRequireUserConsent)].contains(status) {
            state.finderAutomationError = "暂时无法检查 Finder 授权，请打开 Finder 后重试。"
        }
        return state
    }

    func request(_ permission: FinderJumpPermission) async {
        switch permission {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            openSettings("Privacy_Accessibility")
        case .finderAutomation:
            // 系统授权提示可能等待用户操作，不能阻塞 AppKit 主线程。
            let status = await automation.finderPermission(prompt: true)
            if !Task.isCancelled, status != noErr, status != errAETimeout { openSettings("Privacy_Automation") }
        case .postEvents:
            if !CGRequestPostEventAccess() { openSettings("Privacy_Accessibility") }
        case .listenEvents:
            if !CGRequestListenEventAccess() { openSettings("Privacy_ListenEvent") }
        }
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 每种操作最多有一个系统调用在途。静默查询挂起时，显式授权仍可以独立发起。
private actor FinderJumpAutomationAuthorizer {
    private var operations: [Bool: FinderJumpPermissionOperation] = [:]

    func finderPermission(prompt: Bool) async -> OSStatus {
        guard !Task.isCancelled else { return OSStatus(userCanceledErr) }
        let operation: FinderJumpPermissionOperation
        if let existing = operations[prompt], !existing.completed { operation = existing }
        else { operation = FinderJumpPermissionOperation(prompt: prompt); operations[prompt] = operation }
        return await operation.value(timeout: prompt ? 60 : 2)
    }
}

/// 系统 API 没有取消接口；超时只结束等待，不积累新的阻塞调用或阻塞协作线程池。
private final class FinderJumpPermissionOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var result: OSStatus?
    private var timedOut = false
    private var waiters: [UUID: CheckedContinuation<OSStatus, Never>] = [:]

    var completed: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }

    init(prompt: Bool) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
            let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(kAECoreSuite),
                                                              AEEventID(kAEGetData), prompt)
            lock.lock(); result = status
            let pending = Array(waiters.values); waiters.removeAll(); lock.unlock()
            pending.forEach { $0.resume(returning: status) }
        }
    }

    func value(timeout: TimeInterval) async -> OSStatus {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(returning: result); return }
            if timedOut { lock.unlock(); continuation.resume(returning: OSStatus(errAETimeout)); return }
            let id = UUID(); waiters[id] = continuation; lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [self] in
                lock.lock()
                let pending = waiters.removeValue(forKey: id)
                if pending != nil { timedOut = true }
                lock.unlock()
                pending?.resume(returning: OSStatus(errAETimeout))
            }
        }
    }
}
