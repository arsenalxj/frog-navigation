import AppKit
import Carbon
import XCTest
@testable import Frog

private enum FinderJumpTestError: LocalizedError {
    case failed
    var errorDescription: String? { "测试失败" }
}

@MainActor
private final class FakeFinderJumpPermissions: FinderJumpPermissionChecking {
    var state = FinderJumpPermissionState(accessibility: true, finderAutomation: true, postEvents: true, listenEvents: true)
    var checks = 0
    var requested: [FinderJumpPermission] = []
    var holdChecks = false
    var holdRequests = false
    var pendingChecks: [CheckedContinuation<FinderJumpPermissionState, Never>] = []
    var pendingRequests: [CheckedContinuation<Void, Never>] = []

    func check() async -> FinderJumpPermissionState {
        checks += 1
        if holdChecks { return await withCheckedContinuation { pendingChecks.append($0) } }
        return state
    }
    func request(_ permission: FinderJumpPermission) async {
        requested.append(permission)
        if holdRequests { await withCheckedContinuation { pendingRequests.append($0) } }
    }
    func finishCheck(at index: Int = 0, with result: FinderJumpPermissionState? = nil) {
        pendingChecks.remove(at: index).resume(returning: result ?? state)
    }
    func finishRequest() { pendingRequests.removeFirst().resume() }
}

@MainActor
private final class FakeFinderJumpBackend: FinderJumpBackend {
    var onChange: (() -> Void)?
    var target: FinderJumpTarget? = FinderJumpTarget(hostPID: 100, elementPID: 101,
        frame: CGRect(x: 100, y: 100, width: 600, height: 400), identity: "test-panel")
    var location: URL? = URL(fileURLWithPath: "/Users/test/项目 资料", isDirectory: true)
    var starts = 0
    var stops = 0
    var refreshes = 0
    var navigations = 0
    var holdNavigation = false
    var cancelledNavigations = 0
    var pendingNavigations: [CheckedContinuation<Void, Error>] = []
    var pendingNavigation: CheckedContinuation<Void, Error>? { pendingNavigations.first }
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func refresh() { refreshes += 1 }
    func navigate() async throws {
        navigations += 1
        defer { if Task.isCancelled { cancelledNavigations += 1 } }
        if holdNavigation { try await withCheckedThrowingContinuation { pendingNavigations.append($0) } }
    }
    func finishNavigation(_ result: Result<Void, Error>) {
        guard !pendingNavigations.isEmpty else { return }
        pendingNavigations.removeFirst().resume(with: result)
    }
}

private final class FakeFinderJumpWorker: FinderJumpWorking {
    struct Refresh {
        let frontPID: pid_t
        let readsFinder: Bool
        let event: (Bool) -> Void
        let completion: (FinderJumpWorkerState) -> Void
    }
    var refreshes: [Refresh] = []
    var stops = 0
    func stop() { stops += 1 }
    func refresh(frontPID: pid_t, finderPID: pid_t?, readsFinder: Bool, token: UInt64, gate: FinderJumpSessionGate,
                 event: @escaping (Bool) -> Void, completion: @escaping (FinderJumpWorkerState) -> Void) {
        refreshes.append(Refresh(frontPID: frontPID, readsFinder: readsFinder, event: event, completion: completion))
    }
    func navigate(target: FinderJumpTarget, location: URL, token: UInt64, gate: FinderJumpSessionGate,
                  cancellation: FinderJumpNavigationCancellation, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
}

@MainActor
private final class FakeFinderJumpOverlay: FinderJumpOverlayPresenting {
    struct Presentation {
        let directory: URL
        let target: FinderJumpTarget
        let shortcutAvailable: Bool
        let navigating: Bool
    }
    var onActivate: (() -> Void)?
    var presentation: Presentation?
    var shows = 0
    var hides = 0
    func show(directory: URL, target: FinderJumpTarget, shortcutAvailable: Bool, navigating: Bool) {
        shows += 1
        presentation = Presentation(directory: directory, target: target, shortcutAvailable: shortcutAvailable, navigating: navigating)
    }
    func hide() { hides += 1; presentation = nil }
}

@MainActor
private final class FakeFinderJumpHotKey: FinderJumpHotKeyMonitoring {
    var onTrigger: (() -> Void)?
    var onFailure: (() -> Void)?
    var starts = 0
    var stops = 0
    var fails = false
    var targetPID: Int32?
    var sessionID: String?
    func start() throws {
        starts += 1
        if fails { throw FinderJumpTestError.failed }
    }
    func setTargetPID(_ pid: Int32?, sessionID: String?) { targetPID = pid; self.sessionID = sessionID }
    func stop() { stops += 1; targetPID = nil; sessionID = nil }
}

@MainActor
private final class FinderJumpFixture {
    let backend = FakeFinderJumpBackend()
    let permissions = FakeFinderJumpPermissions()
    let overlay = FakeFinderJumpOverlay()
    let hotKey = FakeFinderJumpHotKey()
    let controller: FinderJumpController
    init(defaults: UserDefaults? = nil, observeSystemEvents: Bool = false) {
        controller = FinderJumpController(backend: backend, permissions: permissions, overlay: overlay,
            hotKey: hotKey, defaults: defaults, observeSystemEvents: observeSystemEvents)
    }
    func enable() { controller.start(); controller.setEnabled(true) }
}

@MainActor
final class FinderJumpTests: XCTestCase {
    func testDefaultDisabledDoesNotCheckPermissionsOrStartSystemServices() {
        let fixture = FinderJumpFixture()
        fixture.controller.start(); fixture.controller.start(); fixture.controller.refresh()
        XCTAssertFalse(fixture.controller.enabled)
        XCTAssertFalse(fixture.controller.checkingPermissions)
        XCTAssertFalse(fixture.controller.running)
        XCTAssertEqual(fixture.permissions.checks, 0)
        XCTAssertEqual(fixture.permissions.requested, [])
        XCTAssertEqual(fixture.backend.starts, 0)
        XCTAssertEqual(fixture.hotKey.starts, 0)
        XCTAssertEqual(fixture.overlay.shows, 0)
        fixture.controller.stop()
    }

    func testEnableStartsOnceWithPermissionsAndDisableStopsImmediately() async {
        let fixture = FinderJumpFixture()
        fixture.enable()
        await eventually { fixture.controller.running && fixture.hotKey.targetPID != nil }
        fixture.controller.start(); fixture.controller.setEnabled(true)
        XCTAssertEqual(fixture.backend.starts, 1)
        XCTAssertEqual(fixture.hotKey.starts, 1)
        XCTAssertEqual(fixture.hotKey.targetPID, fixture.backend.target?.hostPID)
        XCTAssertNotEqual(fixture.hotKey.targetPID, fixture.backend.target?.elementPID, "快捷键用前台宿主 PID，不误用 XPC 内容 PID")
        fixture.controller.setEnabled(false)
        XCTAssertFalse(fixture.controller.running)
        XCTAssertFalse(fixture.controller.shortcutAvailable)
        XCTAssertEqual(fixture.backend.stops, 1)
        XCTAssertEqual(fixture.hotKey.stops, 1)
        XCTAssertNil(fixture.hotKey.targetPID)
        XCTAssertNil(fixture.overlay.presentation)
        fixture.backend.onChange?(); fixture.hotKey.onTrigger?(); fixture.overlay.onActivate?()
        XCTAssertNil(fixture.overlay.presentation)
        XCTAssertEqual(fixture.backend.navigations, 0)
        fixture.controller.stop()
    }

    func testMissingRequiredPermissionsBlockServiceAndOnlyFirstMissingIsRequested() async {
        let fixture = FinderJumpFixture()
        fixture.permissions.state = FinderJumpPermissionState()
        fixture.enable()
        await eventually { fixture.permissions.requested == [.accessibility] && !fixture.controller.requestingPermission }
        XCTAssertFalse(fixture.controller.running)
        XCTAssertEqual(fixture.backend.starts, 0)
        XCTAssertEqual(fixture.hotKey.starts, 0)
        XCTAssertNil(fixture.overlay.presentation)
        fixture.permissions.state = FinderJumpPermissionState(accessibility: true, finderAutomation: true, postEvents: true, listenEvents: true)
        fixture.controller.refresh()
        await eventually { fixture.controller.running }
        XCTAssertEqual(fixture.backend.starts, 1)
        XCTAssertEqual(fixture.permissions.requested, [.accessibility], "刷新只检查，不串联弹出全部授权")
        fixture.controller.stop()
    }

    func testMissingKeyboardListeningPermissionKeepsClickableOverlayAndPassesShortcut() async {
        let fixture = FinderJumpFixture()
        fixture.permissions.state.listenEvents = false
        fixture.enable()
        await eventually {
            fixture.controller.running && !fixture.controller.requestingPermission
                && !fixture.permissions.requested.isEmpty && fixture.overlay.presentation != nil
        }
        XCTAssertFalse(fixture.controller.shortcutAvailable)
        XCTAssertEqual(fixture.hotKey.starts, 0)
        XCTAssertNil(fixture.hotKey.targetPID)
        XCTAssertNotNil(fixture.overlay.presentation)
        XCTAssertFalse(fixture.overlay.presentation?.shortcutAvailable ?? true)
        fixture.overlay.onActivate?()
        await eventually { fixture.backend.navigations == 1 && !fixture.controller.navigating }
        fixture.controller.stop()
    }

    func testRequiredPermissionRevocationStopsServicesAndNewGrantCanRecover() async {
        let fixture = FinderJumpFixture()
        fixture.enable()
        await eventually { fixture.controller.running }
        fixture.permissions.state.finderAutomation = false
        fixture.controller.refresh()
        await eventually { !fixture.controller.running }
        XCTAssertNil(fixture.overlay.presentation)
        XCTAssertNil(fixture.hotKey.targetPID)
        XCTAssertEqual(fixture.backend.stops, 1)
        fixture.permissions.state.finderAutomation = true
        fixture.controller.refresh()
        await eventually { fixture.controller.running }
        XCTAssertEqual(fixture.backend.starts, 2)
        fixture.controller.stop()
    }

    func testNoDirectoryOrNoPanelHidesEntryAndUnarmsControlGUntilBothReturn() async {
        let fixture = FinderJumpFixture()
        let directory = fixture.backend.location
        let target = fixture.backend.target
        fixture.backend.location = nil
        fixture.enable()
        await eventually { fixture.controller.running }
        XCTAssertNil(fixture.overlay.presentation)
        XCTAssertNil(fixture.hotKey.targetPID)
        fixture.backend.location = directory; fixture.backend.onChange?()
        XCTAssertEqual(fixture.overlay.presentation?.directory, directory)
        XCTAssertEqual(fixture.hotKey.targetPID, target?.hostPID)
        fixture.backend.target = nil; fixture.backend.onChange?()
        XCTAssertNil(fixture.overlay.presentation)
        XCTAssertNil(fixture.hotKey.targetPID)
        fixture.backend.target = target; fixture.backend.onChange?()
        XCTAssertNotNil(fixture.overlay.presentation)
        fixture.controller.stop()
    }

    func testLauncherShortcutConflictRetainsClickEntryAndRecoversWhenBindingChanges() async {
        let fixture = FinderJumpFixture()
        fixture.controller.setLauncherShortcut(HotKeyConfiguration(enabled: true, shortcut: FinderJumpHotKey.shortcut))
        fixture.enable()
        await eventually { fixture.controller.running }
        XCTAssertTrue(fixture.controller.shortcutConflict)
        XCTAssertEqual(fixture.hotKey.starts, 0)
        XCTAssertNotNil(fixture.overlay.presentation)
        XCTAssertNil(fixture.hotKey.targetPID)
        fixture.controller.setLauncherShortcut(HotKeyConfiguration())
        XCTAssertFalse(fixture.controller.shortcutConflict)
        XCTAssertTrue(fixture.controller.shortcutAvailable)
        XCTAssertEqual(fixture.hotKey.targetPID, fixture.backend.target?.hostPID)
        fixture.controller.stop()
    }

    func testHotKeyStartFailureKeepsClickableEntryAndRetryRestoresShortcut() async {
        let fixture = FinderJumpFixture()
        fixture.hotKey.fails = true
        fixture.enable()
        await eventually { fixture.controller.running && fixture.controller.error != nil }
        XCTAssertFalse(fixture.controller.shortcutAvailable)
        XCTAssertNil(fixture.hotKey.targetPID)
        XCTAssertNotNil(fixture.overlay.presentation)
        fixture.hotKey.fails = false; fixture.controller.refresh()
        await eventually { fixture.controller.shortcutAvailable }
        XCTAssertNil(fixture.controller.error)
        fixture.controller.stop()
    }

    func testSavedEnabledPreferenceRestoresWithoutPromptAndIsolationLeavesStandardDefaultsUntouched() async throws {
        let name = "Frog-FinderJump-Tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = FinderJumpFixture(defaults: defaults)
        first.enable()
        await eventually { first.controller.running }
        first.controller.stop()
        XCTAssertTrue(defaults.bool(forKey: FinderJumpController.preferencesKey))
        let restored = FinderJumpFixture(defaults: defaults)
        restored.controller.start()
        await eventually { restored.controller.running }
        XCTAssertEqual(restored.permissions.requested, [])
        restored.controller.setEnabled(false); restored.controller.stop()
        XCTAssertFalse(FinderJumpFixture(defaults: defaults).controller.enabled)

        let before = UserDefaults.standard.object(forKey: FinderJumpController.preferencesKey) as? NSObject
        let isolated = FinderJumpFixture()
        isolated.enable()
        await eventually { isolated.controller.running }
        isolated.controller.stop()
        XCTAssertEqual(UserDefaults.standard.object(forKey: FinderJumpController.preferencesKey) as? NSObject, before)
        XCTAssertFalse(FinderJumpFixture().controller.enabled)
    }

    func testLatePermissionCheckCannotRestartDisabledFeatureOrReplaceNewerResult() async {
        let fixture = FinderJumpFixture()
        fixture.permissions.holdChecks = true
        fixture.enable()
        XCTAssertTrue(fixture.controller.checkingPermissions, "开启后即显示检查状态，不把初始 false 当成权限被拒")
        await eventually { fixture.permissions.pendingChecks.count == 1 }
        fixture.controller.setEnabled(false)
        XCTAssertFalse(fixture.controller.checkingPermissions, "关闭同步清除检查状态")
        fixture.permissions.finishCheck()
        await drainTasks()
        XCTAssertFalse(fixture.controller.checkingPermissions, "过期检查结果不能恢复检查状态")
        XCTAssertFalse(fixture.controller.running)
        XCTAssertEqual(fixture.backend.starts, 0)
        XCTAssertEqual(fixture.permissions.requested, [])

        fixture.controller.setEnabled(true)
        await eventually { fixture.permissions.pendingChecks.count == 1 }
        fixture.controller.refresh()
        XCTAssertTrue(fixture.controller.checkingPermissions)
        await eventually { fixture.permissions.pendingChecks.count == 2 }
        fixture.permissions.finishCheck(at: 1)
        await eventually { fixture.controller.running }
        XCTAssertFalse(fixture.controller.checkingPermissions)
        fixture.permissions.finishCheck(with: FinderJumpPermissionState())
        await drainTasks()
        XCTAssertTrue(fixture.controller.running)
        XCTAssertTrue(fixture.controller.permissions.canNavigate)
        XCTAssertFalse(fixture.controller.checkingPermissions)
        fixture.controller.stop()
    }

    func testPendingPermissionRequestSurvivesRefreshAndOldRequestCannotFinishNewEnableSession() async {
        let fixture = FinderJumpFixture()
        fixture.permissions.state = FinderJumpPermissionState()
        fixture.permissions.holdRequests = true
        fixture.enable()
        await eventually { fixture.permissions.pendingRequests.count == 1 }
        fixture.controller.refresh()
        await drainTasks()
        XCTAssertTrue(fixture.controller.requestingPermission)
        fixture.permissions.finishRequest()
        await eventually { !fixture.controller.requestingPermission }

        fixture.controller.requestPermission(.accessibility)
        await eventually { fixture.permissions.pendingRequests.count == 1 }
        fixture.controller.setEnabled(false); fixture.controller.setEnabled(true)
        await eventually { fixture.permissions.pendingRequests.count == 2 }
        fixture.permissions.finishRequest()
        await drainTasks()
        XCTAssertTrue(fixture.controller.requestingPermission, "旧授权回调不能清理新一轮请求状态")
        fixture.permissions.state = FinderJumpPermissionState(accessibility: true, finderAutomation: true, postEvents: true, listenEvents: true)
        fixture.permissions.finishRequest()
        await eventually { !fixture.controller.requestingPermission && fixture.controller.running }
        fixture.controller.stop()
    }

    func testPendingPermissionRefreshCannotRearmFromBackendOrShortcutChanges() async {
        let fixture = FinderJumpFixture()
        fixture.enable()
        await eventually { fixture.controller.running && fixture.overlay.presentation != nil }
        fixture.permissions.holdChecks = true
        fixture.controller.refresh()
        XCTAssertTrue(fixture.controller.checkingPermissions)
        fixture.backend.onChange?()
        fixture.controller.setLauncherShortcut(HotKeyConfiguration(enabled: true, shortcut: FinderJumpHotKey.shortcut))
        fixture.controller.setLauncherShortcut(HotKeyConfiguration())
        XCTAssertNil(fixture.overlay.presentation, "待验权时旧 AX 回调和快捷键配置不能恢复入口")
        XCTAssertNil(fixture.hotKey.targetPID)
        await eventually { fixture.permissions.pendingChecks.count == 1 }
        fixture.permissions.finishCheck()
        await eventually { !fixture.controller.checkingPermissions && fixture.overlay.presentation != nil }
        XCTAssertEqual(fixture.hotKey.targetPID, fixture.backend.target?.hostPID)
        fixture.controller.stop()
    }

    func testDisableCancelsNavigationAndIgnoresLateFailureWithoutReopeningOverlay() async {
        let fixture = FinderJumpFixture()
        fixture.backend.holdNavigation = true
        fixture.enable()
        await eventually { fixture.controller.running }
        fixture.overlay.onActivate?()
        await eventually { fixture.backend.pendingNavigation != nil }
        XCTAssertTrue(fixture.controller.navigating)
        XCTAssertNil(fixture.hotKey.targetPID)
        fixture.overlay.onActivate?(); fixture.hotKey.onTrigger?()
        XCTAssertEqual(fixture.backend.navigations, 1)
        fixture.controller.setEnabled(false)
        fixture.backend.finishNavigation(.failure(FinderJumpTestError.failed))
        await drainTasks()
        XCTAssertFalse(fixture.controller.navigating)
        XCTAssertFalse(fixture.controller.running)
        XCTAssertNil(fixture.controller.error)
        XCTAssertNil(fixture.overlay.presentation)
        XCTAssertNil(fixture.hotKey.targetPID)
        fixture.controller.stop()
    }

    func testNavigationDoesNotJumpNewPanelAfterAsyncPermissionCheck() async {
        let fixture = FinderJumpFixture()
        fixture.enable()
        await eventually { fixture.controller.running }
        fixture.permissions.holdChecks = true
        fixture.overlay.onActivate?()
        await eventually { fixture.permissions.pendingChecks.count == 1 }
        fixture.backend.target = FinderJumpTarget(hostPID: 200, elementPID: 201,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400), identity: "different-panel")
        fixture.backend.onChange?()
        fixture.permissions.finishCheck()
        await eventually { !fixture.controller.navigating }
        XCTAssertEqual(fixture.backend.navigations, 0)
        fixture.controller.stop()
    }

    func testSessionSuspensionStopsNavigationBeforeSlowPermissionCheckAndResumeRechecks() async {
        // 只向本进程的通知中心投递测试通知；不会调用系统睡眠或会话切换接口。
        let fixture = FinderJumpFixture(observeSystemEvents: true)
        fixture.backend.holdNavigation = true
        fixture.enable()
        await eventually { fixture.controller.running }
        fixture.overlay.onActivate?()
        await eventually { fixture.backend.pendingNavigation != nil }
        fixture.permissions.holdChecks = true
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        XCTAssertFalse(fixture.controller.running, "收到暂停事件后同步停止，不等待权限 IPC")
        XCTAssertFalse(fixture.controller.navigating)
        XCTAssertNil(fixture.overlay.presentation)
        XCTAssertNil(fixture.hotKey.targetPID)
        XCTAssertEqual(fixture.permissions.pendingChecks.count, 0)
        fixture.backend.finishNavigation(.failure(FinderJumpTestError.failed))
        await drainTasks()
        XCTAssertNil(fixture.controller.error)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        await eventually { fixture.permissions.pendingChecks.count == 1 }
        XCTAssertFalse(fixture.controller.running)
        fixture.permissions.finishCheck()
        await eventually { fixture.controller.running }
        fixture.controller.stop()
    }

    func testForegroundFrogSkipsOwnAXTreeButKeepsFinderTrackingAndExternalPanels() async {
        let worker = FakeFinderJumpWorker()
        var foreground = getpid()
        let backend = NativeFinderJumpBackend(worker: worker, observeSystemEvents: false, frontmostPID: { foreground })
        defer { backend.stop() }
        let directory = FakeFinderJumpBackend().location
        backend.start()
        XCTAssertEqual(worker.refreshes[0].frontPID, 0, "后台线程不能读取自身 SwiftUI 的辅助功能树")
        XCTAssertTrue(worker.refreshes[0].readsFinder, "自身前台期间仍追踪 Finder 的最后目录")
        worker.refreshes[0].completion(.init(target: nil, location: directory))
        await eventually { backend.location == directory }
        XCTAssertNil(backend.target)

        foreground = 100
        backend.refresh()
        XCTAssertEqual(worker.refreshes[1].frontPID, 100)
        let target = FakeFinderJumpBackend().target
        worker.refreshes[1].completion(.init(target: target, location: directory))
        await eventually { backend.target == target }

        foreground = getpid()
        backend.refresh()
        XCTAssertNil(backend.target, "切回启动台立即清空其他应用的快跳目标")
        XCTAssertEqual(worker.refreshes[2].frontPID, 0)
        worker.refreshes[2].completion(.init(target: nil, location: directory))
        await drainTasks()
        XCTAssertNil(backend.target)
        XCTAssertEqual(backend.location, directory)
    }

    func testOldPanelScanCannotRestoreEntryOrShortcutAfterInvalidation() async {
        let worker = FakeFinderJumpWorker()
        let backend = NativeFinderJumpBackend(worker: worker, observeSystemEvents: false, frontmostPID: { 100 })
        let overlay = FakeFinderJumpOverlay()
        let hotKey = FakeFinderJumpHotKey()
        let controller = FinderJumpController(backend: backend, permissions: FakeFinderJumpPermissions(),
            overlay: overlay, hotKey: hotKey, defaults: nil, observeSystemEvents: false)
        defer { controller.stop() }
        controller.start(); controller.setEnabled(true)
        await eventually { worker.refreshes.count == 1 }
        let state = FinderJumpWorkerState(target: FakeFinderJumpBackend().target, location: FakeFinderJumpBackend().location)
        worker.refreshes[0].completion(state)
        await eventually { overlay.presentation != nil }

        backend.refresh()
        XCTAssertEqual(worker.refreshes.count, 2)
        // 窗口关闭事件先到达，已取得旧面板的扫描随后才返回。
        worker.refreshes[0].event(false)
        await drainTasks()
        worker.refreshes[1].completion(state)
        await eventually { worker.refreshes.count == 3 }
        XCTAssertNil(backend.target, "旧扫描不能重新发布已经关闭的面板")
        XCTAssertNil(overlay.presentation)
        XCTAssertNil(hotKey.targetPID, "最新扫描完成前必须放行 Control-G")

        worker.refreshes[2].completion(.init(target: nil, location: state.location))
        await drainTasks()
        XCTAssertNil(overlay.presentation)
        backend.refresh()
        XCTAssertEqual(worker.refreshes.count, 4)
        worker.refreshes[3].completion(state)
        await eventually { overlay.presentation != nil && hotKey.targetPID == 100 }
    }

    func testMergedScansKeepFinderReadAndPublishOnlyLatestResult() async {
        let worker = FakeFinderJumpWorker()
        let backend = NativeFinderJumpBackend(worker: worker, observeSystemEvents: false, frontmostPID: { 100 })
        defer { backend.stop() }
        backend.start()
        worker.refreshes[0].event(false)
        worker.refreshes[0].event(true)
        worker.refreshes[0].event(false)
        await drainTasks()
        XCTAssertEqual(worker.refreshes.count, 1, "扫描期间的事件应合并")
        let state = FinderJumpWorkerState(target: FakeFinderJumpBackend().target, location: FakeFinderJumpBackend().location)
        worker.refreshes[0].completion(state)
        await eventually { worker.refreshes.count == 2 }
        XCTAssertNil(backend.target)
        XCTAssertTrue(worker.refreshes[1].readsFinder, "后续普通事件不能丢弃合并的 Finder 读取请求")
        worker.refreshes[1].completion(state)
        await eventually { backend.target == state.target && backend.location == state.location }
        XCTAssertEqual(worker.refreshes.count, 2)
    }

    func testStoppedSessionEventCannotInvalidateRestartedBackend() async {
        let worker = FakeFinderJumpWorker()
        let backend = NativeFinderJumpBackend(worker: worker, observeSystemEvents: false, frontmostPID: { 100 })
        defer { backend.stop() }
        let state = FinderJumpWorkerState(target: FakeFinderJumpBackend().target, location: FakeFinderJumpBackend().location)
        backend.start(); worker.refreshes[0].completion(state)
        await eventually { backend.target != nil }
        backend.stop(); backend.start()
        XCTAssertEqual(worker.refreshes.count, 2)
        worker.refreshes[1].completion(state)
        await eventually { backend.target != nil }
        worker.refreshes[0].event(true)
        await drainTasks()
        XCTAssertEqual(backend.target, state.target, "旧观察器排队中的事件不能清空新会话面板")
        XCTAssertEqual(worker.refreshes.count, 2)
    }

    func testStoppedScanCompletionCannotFinishOrPublishIntoRestartedScan() async {
        let worker = FakeFinderJumpWorker()
        let backend = NativeFinderJumpBackend(worker: worker, observeSystemEvents: false, frontmostPID: { 100 })
        defer { backend.stop() }
        let state = FinderJumpWorkerState(target: FakeFinderJumpBackend().target, location: FakeFinderJumpBackend().location)
        backend.start(); backend.stop(); backend.start()
        XCTAssertEqual(worker.refreshes.count, 2, "重启不应沿用已停止会话的扫描调度状态")
        guard worker.refreshes.count == 2 else {
            worker.refreshes[0].completion(state)
            await drainTasks()
            return
        }
        backend.refresh()
        worker.refreshes[0].completion(state)
        await drainTasks()
        XCTAssertNil(backend.target)
        XCTAssertEqual(worker.refreshes.count, 2, "旧回调不能结束新扫描并提前派发合并请求")
        worker.refreshes[1].completion(state)
        await eventually { worker.refreshes.count == 3 }
        XCTAssertNil(backend.target)
        worker.refreshes[2].completion(state)
        await eventually { backend.target == state.target }
    }

    func testApplicationSwitchCancelsNavigationWaitingForPermissions() async {
        await verifySwitchCancelsPendingNavigation(NSWorkspace.didActivateApplicationNotification)
    }

    func testSpaceSwitchCancelsNavigationWaitingForPermissions() async {
        await verifySwitchCancelsPendingNavigation(NSWorkspace.activeSpaceDidChangeNotification)
    }

    private func verifySwitchCancelsPendingNavigation(_ notification: Notification.Name) async {
        // 只通知本进程的观察器，不切换真实应用或 Space。
        let fixture = FinderJumpFixture(observeSystemEvents: true)
        defer { fixture.controller.stop() }
        fixture.enable()
        await eventually { fixture.controller.running }
        fixture.permissions.holdChecks = true
        fixture.overlay.onActivate?()
        await eventually { fixture.permissions.pendingChecks.count == 1 }
        let target = fixture.backend.target
        fixture.backend.target = nil
        NSWorkspace.shared.notificationCenter.post(name: notification, object: NSWorkspace.shared)
        XCTAssertFalse(fixture.controller.navigating, "切走后立即取消旧导航，不等待权限返回")
        XCTAssertNil(fixture.overlay.presentation)
        XCTAssertNil(fixture.hotKey.targetPID)
        await eventually { fixture.permissions.pendingChecks.count == 2 }
        fixture.permissions.finishCheck(at: 1)
        await eventually { !fixture.controller.checkingPermissions }

        fixture.backend.target = target
        NSWorkspace.shared.notificationCenter.post(name: notification, object: NSWorkspace.shared)
        await eventually { fixture.permissions.pendingChecks.count == 2 }
        fixture.permissions.finishCheck(at: 1)
        await eventually { !fixture.controller.checkingPermissions }
        fixture.permissions.holdChecks = false
        fixture.permissions.finishCheck()
        await drainTasks()
        XCTAssertEqual(fixture.backend.navigations, 0, "切回相同面板也不能恢复旧请求")
        XCTAssertEqual(fixture.backend.starts, 1)
        XCTAssertEqual(fixture.backend.stops, 0, "应用及 Space 切换保留目录观察服务")
        fixture.overlay.onActivate?()
        await eventually { !fixture.controller.navigating }
        XCTAssertEqual(fixture.backend.navigations, 1, "切回后新点击仍可跳转")
    }

    func testCancelledBackendNavigationCannotFinishNewNavigation() async {
        let fixture = FinderJumpFixture(observeSystemEvents: true)
        defer { fixture.controller.stop() }
        fixture.backend.holdNavigation = true
        fixture.enable()
        await eventually { fixture.controller.running }
        fixture.overlay.onActivate?()
        await eventually { fixture.backend.pendingNavigation != nil }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        XCTAssertFalse(fixture.controller.navigating)
        await eventually { !fixture.controller.checkingPermissions }
        fixture.overlay.onActivate?()
        await eventually { fixture.backend.pendingNavigations.count == 2 }
        let refreshes = fixture.backend.refreshes
        fixture.backend.finishNavigation(.failure(FinderJumpTestError.failed))
        await drainTasks()
        XCTAssertEqual(fixture.backend.cancelledNavigations, 1)
        XCTAssertTrue(fixture.controller.navigating, "旧导航的迟到失败不能结束新导航")
        XCTAssertNil(fixture.controller.error)
        XCTAssertEqual(fixture.backend.refreshes, refreshes)
        XCTAssertNil(fixture.hotKey.targetPID)
        fixture.backend.finishNavigation(.success(()))
        await eventually { !fixture.controller.navigating && fixture.hotKey.targetPID != nil }
    }

    func testOrdinaryRefreshAndBackendChangesDoNotCancelPendingNavigation() async {
        let fixture = FinderJumpFixture()
        defer { fixture.controller.stop() }
        fixture.enable()
        await eventually { fixture.controller.running }
        fixture.permissions.holdChecks = true
        fixture.overlay.onActivate?()
        await eventually { fixture.permissions.pendingChecks.count == 1 }
        fixture.backend.onChange?(); fixture.controller.refresh()
        await eventually { fixture.permissions.pendingChecks.count == 2 }
        fixture.permissions.finishCheck(at: 1)
        await eventually { !fixture.controller.checkingPermissions }
        XCTAssertTrue(fixture.controller.navigating)
        fixture.permissions.holdChecks = false
        fixture.permissions.finishCheck()
        await eventually { fixture.backend.navigations == 1 && !fixture.controller.navigating }
    }

    func testPanelRulesRejectOrdinaryDialogsAndPartialFileControls() {
        let controls = [FinderJumpAXDescription(role: "AXPopUpButton", identifier: "where popup"),
                        FinderJumpAXDescription(role: "AXButton", identifier: "OKButton"),
                        FinderJumpAXDescription(role: "AXButton", identifier: "CancelButton"),
                        FinderJumpAXDescription(role: "AXOutline", identifier: "")]
        XCTAssertTrue(FinderJumpPanelRules.isFilePanel(root: .init(role: "AXSheet", identifier: "open-panel"), descendants: controls))
        XCTAssertFalse(FinderJumpPanelRules.isFilePanel(root: .init(role: "AXSheet", identifier: ""), descendants: controls))
        XCTAssertFalse(FinderJumpPanelRules.isFilePanel(root: .init(role: "AXWindow", identifier: "confirmation"), descendants: controls))
        XCTAssertFalse(FinderJumpPanelRules.isFilePanel(root: .init(role: "AXGroup", identifier: "open-panel"), descendants: controls))
        for index in controls.indices {
            var incomplete = controls
            incomplete.remove(at: index)
            XCTAssertFalse(FinderJumpPanelRules.isFilePanel(root: .init(role: "AXSheet", identifier: "open-panel"), descendants: incomplete))
        }
    }

    func testSessionGateRejectsStoppedAndReplacedSessionsAndWrongForeground() {
        let gate = FinderJumpSessionGate()
        let first = gate.begin(frontPID: 100)
        XCTAssertTrue(gate.accepts(first, hostPID: 100))
        XCTAssertFalse(gate.accepts(first, hostPID: 200))
        gate.setForeground(200)
        XCTAssertFalse(gate.accepts(first, hostPID: 100))
        gate.stop()
        XCTAssertFalse(gate.accepts(first))
        let second = gate.begin(frontPID: 100)
        XCTAssertFalse(gate.accepts(first, hostPID: 100))
        XCTAssertTrue(gate.accepts(second, hostPID: 100))
        gate.stop()
    }

    func testNavigationSessionCannotResumeAfterSwitchingAwayAndBack() {
        let gate = FinderJumpSessionGate()
        let token = gate.begin(frontPID: 100)
        let revision = gate.navigationRevision
        XCTAssertTrue(gate.accepts(token, hostPID: 100, navigationRevision: revision))
        gate.setForeground(100)
        XCTAssertTrue(gate.accepts(token, hostPID: 100, navigationRevision: revision), "相同前台的普通刷新不取消导航")
        gate.setForeground(200); gate.setForeground(100)
        XCTAssertFalse(gate.accepts(token, hostPID: 100, navigationRevision: revision), "切回原应用不能恢复旧导航")
        XCTAssertTrue(gate.accepts(token, hostPID: 100, navigationRevision: gate.navigationRevision), "当前面板可开始新导航")
        gate.stop()
    }

    func testSpaceChangeInvalidatesNavigationWithoutStoppingDirectoryObservationSession() {
        let gate = FinderJumpSessionGate()
        let token = gate.begin(frontPID: 100)
        let revision = gate.navigationRevision
        gate.invalidateNavigation()
        XCTAssertTrue(gate.accepts(token, hostPID: 100))
        XCTAssertFalse(gate.accepts(token, hostPID: 100, navigationRevision: revision))
        XCTAssertTrue(gate.accepts(token, hostPID: 100, navigationRevision: gate.navigationRevision))
        gate.stop()
    }

    func testNavigationReadinessWaitsForValidFocusBeforeReadingPanel() throws {
        var validations = 0
        var reads = 0
        let result: String = try FinderJumpNavigation.waitForReadiness(seconds: 1, validate: {
            validations += 1
            if validations == 1 { throw FinderJumpNavigationError.accessibilityBusy }
        }, read: {
            reads += 1
            XCTAssertEqual(validations, 2, "远程面板暂不可读期间不能执行依赖焦点的读取")
            return "目标面板"
        })
        XCTAssertEqual(result, "目标面板")
        XCTAssertEqual(validations, 2)
        XCTAssertEqual(reads, 1)
    }

    func testNavigationReadinessStopsWhenTemporaryUnavailabilityBecomesFocusChange() {
        var validations = 0
        var reads = 0
        XCTAssertThrowsError(try FinderJumpNavigation.waitForReadiness(seconds: 1, validate: {
            validations += 1
            if validations == 1 { throw FinderJumpNavigationError.accessibilityBusy }
            throw FinderJumpNavigationError.changedFocus
        }, read: { () -> Bool? in
            reads += 1
            return true
        })) { error in
            guard case FinderJumpNavigationError.changedFocus = error else {
                return XCTFail("确定切换窗口时应立即停止：\(error)")
            }
        }
        XCTAssertEqual(validations, 2)
        XCTAssertEqual(reads, 0)
    }

    func testNavigationReadinessTimesOutWithoutReadingAnUnavailablePanel() {
        var reads = 0
        XCTAssertThrowsError(try FinderJumpNavigation.waitForReadiness(seconds: 0.08, validate: {
            throw FinderJumpNavigationError.accessibilityBusy
        }, read: { () -> Bool? in
            reads += 1
            return true
        })) { error in
            guard case FinderJumpNavigationError.timedOut = error else {
                return XCTFail("持续不可读应按期限停止：\(error)")
            }
        }
        XCTAssertEqual(reads, 0)
    }

    func testNavigationReadinessDoesNotRetryOtherErrors() {
        var validations = 0
        var reads = 0
        XCTAssertThrowsError(try FinderJumpNavigation.waitForReadiness(seconds: 1, validate: {
            validations += 1
            throw FinderJumpTestError.failed
        }, read: { () -> Bool? in
            reads += 1
            return true
        })) { error in
            guard case FinderJumpTestError.failed = error else {
                return XCTFail("原始错误应原样返回：\(error)")
            }
        }
        XCTAssertEqual(validations, 1)
        XCTAssertEqual(reads, 0)
    }

    func testDirectoryCacheKeepsLastRealDirectoryWhenFinderClosesOrVisitsVirtualLocation() {
        var cache = FinderJumpLocationCache()
        let directory = URL(fileURLWithPath: "/Users/test/项目 资料", isDirectory: true)
        cache.accept(directory, isDirectory: { $0 == directory })
        cache.accept(nil, isDirectory: { _ in true })
        cache.accept(URL(string: "x-apple-finder:recent")!, isDirectory: { _ in true })
        cache.accept(URL(fileURLWithPath: "/Users/test/搜索.savedSearch"), isDirectory: { _ in true })
        cache.accept(URL(fileURLWithPath: "/Users/test/分类.smartFolder"), isDirectory: { _ in true })
        cache.accept(URL(fileURLWithPath: "/Users/test/文件.txt"), isDirectory: { _ in false })
        XCTAssertEqual(cache.lastDirectory, directory.standardizedFileURL)
        XCTAssertEqual(cache.validDirectory(isDirectory: { $0 == directory.standardizedFileURL }), directory.standardizedFileURL)
        XCTAssertNil(FinderJumpLocationCache().lastDirectory, "新运行的缓存不继承上次目录")
    }

    func testDirectoryCacheHidesUnavailableLocationAndAcceptsNextValidDirectory() {
        var cache = FinderJumpLocationCache()
        let disconnected = URL(fileURLWithPath: "/Volumes/External/项目", isDirectory: true)
        let next = URL(fileURLWithPath: "/Users/test/Documents", isDirectory: true)
        cache.accept(disconnected, isDirectory: { _ in true })
        XCTAssertNil(cache.validDirectory(isDirectory: { _ in false }))
        XCTAssertEqual(cache.lastDirectory, disconnected.standardizedFileURL)
        cache.accept(next, isDirectory: { $0 == next })
        XCTAssertEqual(cache.validDirectory(isDirectory: { $0 == next }), next.standardizedFileURL)
    }

    func testDirectoryValidationObservesDeletionWithoutTreatingAFileAsDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Frog-FinderJump-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("文件.txt")
        try Data("test".utf8).write(to: file)
        var cache = FinderJumpLocationCache()
        cache.accept(root)
        XCTAssertEqual(cache.validDirectory(), root.standardizedFileURL)
        cache.accept(file)
        XCTAssertEqual(cache.lastDirectory, root.standardizedFileURL)
        try FileManager.default.removeItem(at: root)
        XCTAssertNil(cache.validDirectory())
    }

    func testControlGPassesThroughWithoutEligibilityAndForOtherModifiersOrInjectedEvents() {
        var gate = FinderJumpKeyGate()
        XCTAssertEqual(key(&gate, eligible: false), .pass)
        XCTAssertEqual(key(&gate, type: .keyUp, eligible: false), .pass)
        for flags: CGEventFlags in [[], .maskCommand, .maskAlternate, [.maskControl, .maskShift],
                                   [.maskControl, .maskCommand], [.maskControl, .maskSecondaryFn]] {
            XCTAssertEqual(key(&gate, flags: flags), .pass)
        }
        XCTAssertEqual(key(&gate, code: Int64(kVK_ANSI_H)), .pass)
        XCTAssertEqual(key(&gate, isRepeat: true), .pass)
        XCTAssertEqual(key(&gate, injected: true), .pass)
        XCTAssertFalse(gate.held)
    }

    func testControlGTriggersOnceAndConsumesMatchingRepeatAndReleaseAfterEligibilityChanges() {
        var gate = FinderJumpKeyGate()
        XCTAssertEqual(key(&gate), .trigger)
        XCTAssertEqual(key(&gate, isRepeat: true), .consume)
        XCTAssertEqual(key(&gate, flags: [], isRepeat: true, eligible: false), .consume)
        XCTAssertEqual(key(&gate, type: .keyUp, flags: [], eligible: false), .consume)
        XCTAssertFalse(gate.held)
        XCTAssertEqual(key(&gate, eligible: false), .pass)
        XCTAssertEqual(key(&gate, type: .keyUp, eligible: false), .pass)
        XCTAssertEqual(key(&gate), .trigger)
        XCTAssertEqual(key(&gate, type: .keyUp), .consume)
    }

    func testInjectedEventsAndUnrelatedKeyReleasesDoNotCompletePhysicalControlGPress() {
        var gate = FinderJumpKeyGate()
        XCTAssertEqual(key(&gate, flags: [.maskControl, .maskAlphaShift]), .trigger)
        XCTAssertEqual(key(&gate, type: .keyUp, injected: true), .pass)
        XCTAssertEqual(key(&gate, type: .keyUp, code: Int64(kVK_ANSI_H)), .pass)
        XCTAssertTrue(gate.held)
        XCTAssertEqual(key(&gate, type: .keyUp), .consume)
        XCTAssertEqual(key(&gate, type: .keyUp), .pass)
    }

    func testOverlayConvertsAXCoordinatesAndPlacesBelowWithSixPointGap() throws {
        let screen = FinderJumpScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
        let result = try XCTUnwrap(FinderJumpOverlayLayout.frame(
            targetAXFrame: CGRect(x: 400, y: 200, width: 600, height: 400), screens: [screen], primaryScreenHeight: 900))
        XCTAssertEqual(result, CGRect(x: 440, y: 250, width: 520, height: 44))
        XCTAssertTrue(screen.visibleFrame.contains(result))
    }

    func testOverlayMovesAboveAtBottomAndHidesWhenNeitherSideFits() throws {
        let screen = FinderJumpScreen(frame: CGRect(x: 0, y: 0, width: 1000, height: 900),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 875))
        let above = try XCTUnwrap(FinderJumpOverlayLayout.frame(
            targetAXFrame: CGRect(x: 100, y: 430, width: 600, height: 460), screens: [screen], primaryScreenHeight: 900))
        XCTAssertEqual(above.minY, 476)
        XCTAssertNil(FinderJumpOverlayLayout.frame(
            targetAXFrame: CGRect(x: 100, y: 30, width: 600, height: 850), screens: [screen], primaryScreenHeight: 900))
    }

    func testOverlaySelectsNegativeCoordinateDisplayAndStaysInsideVisibleFrame() throws {
        let main = FinderJumpScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
        let left = FinderJumpScreen(frame: CGRect(x: -1280, y: -200, width: 1280, height: 1024),
                                    visibleFrame: CGRect(x: -1280, y: -160, width: 1280, height: 984))
        let result = try XCTUnwrap(FinderJumpOverlayLayout.frame(
            targetAXFrame: CGRect(x: -1240, y: 260, width: 400, height: 500), screens: [main, left], primaryScreenHeight: 900))
        XCTAssertEqual(result.minX, -1272)
        XCTAssertEqual(result.minY, 90)
        XCTAssertTrue(left.visibleFrame.insetBy(dx: 8, dy: 8).contains(result))
    }

    func testOverlayRejectsInvalidOffscreenAndTooNarrowGeometry() {
        let screen = FinderJumpScreen(frame: CGRect(x: 0, y: 0, width: 200, height: 900),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 200, height: 875))
        for target in [CGRect.zero, CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 300),
                       CGRect(x: 1000, y: 1000, width: 200, height: 300),
                       CGRect(x: 0, y: 100, width: 180, height: 300)] {
            XCTAssertNil(FinderJumpOverlayLayout.frame(targetAXFrame: target, screens: [screen], primaryScreenHeight: 900))
        }
    }

    private func key(_ gate: inout FinderJumpKeyGate, type: CGEventType = .keyDown,
                     code: Int64 = Int64(kVK_ANSI_G), flags: CGEventFlags = .maskControl,
                     isRepeat: Bool = false, injected: Bool = false, eligible: Bool = true) -> FinderJumpKeyGate.Decision {
        gate.handle(type: type, keyCode: code, flags: flags, isRepeat: isRepeat, injected: injected, eligible: eligible)
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "异步状态未按期完成", file: file, line: line)
    }

    private func drainTasks() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
