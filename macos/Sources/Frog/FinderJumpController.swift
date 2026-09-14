import AppKit
import Combine

@MainActor
final class FinderJumpController: ObservableObject {
    static let preferencesKey = "finderJumpEnabled"
    @Published private(set) var enabled: Bool
    @Published private(set) var permissions = FinderJumpPermissionState()
    @Published private(set) var running = false
    @Published private(set) var shortcutAvailable = false
    @Published private(set) var shortcutConflict = false
    @Published private(set) var requestingPermission = false
    @Published private(set) var checkingPermissions = false
    @Published private(set) var navigating = false
    @Published private(set) var error: String?
    private let backend: FinderJumpBackend
    private let permissionChecker: FinderJumpPermissionChecking
    private let overlay: FinderJumpOverlayPresenting
    private let hotKey: FinderJumpHotKeyMonitoring
    private let defaults: UserDefaults?
    private let observeSystemEvents: Bool
    private var started = false
    private var generation = 0
    private var permissionGeneration = 0
    private var refreshGeneration = 0
    private var navigationTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var permissionRefreshTask: Task<Void, Never>?
    private var shouldRequestPermissionOnRefresh = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []
    private var suspensions: Set<String> = []

    init(backend: FinderJumpBackend, permissions: FinderJumpPermissionChecking,
         overlay: FinderJumpOverlayPresenting, hotKey: FinderJumpHotKeyMonitoring,
         defaults: UserDefaults? = .standard, observeSystemEvents: Bool = true) {
        self.backend = backend; permissionChecker = permissions
        self.overlay = overlay; self.hotKey = hotKey
        self.defaults = defaults; self.observeSystemEvents = observeSystemEvents
        enabled = defaults?.bool(forKey: Self.preferencesKey) ?? false
        backend.onChange = { [weak self] in self?.backendChanged() }
        overlay.onActivate = { [weak self] in self?.navigate() }
        hotKey.onTrigger = { [weak self] in self?.navigate() }
        hotKey.onFailure = { [weak self] in
            guard let self, self.started, self.enabled else { return }
            self.hotKey.stop(); self.shortcutAvailable = false
            self.error = "⌃G 监听已暂停，请检查键盘监听权限后重试。目录入口仍可点击。"
            self.refresh(retryHotKey: false)
        }
    }

    convenience init(defaults: UserDefaults? = .standard) {
        self.init(backend: NativeFinderJumpBackend(), permissions: NativeFinderJumpPermissions(),
                  overlay: FinderJumpOverlay(), hotKey: FinderJumpHotKey(), defaults: defaults)
    }

    func start() {
        guard !started else { return }
        started = true
        if enabled { installObservers(); refresh() }
    }

    func stop() {
        started = false
        stopServices(); removeObservers()
        cancelRefresh()
        shouldRequestPermissionOnRefresh = false
        permissionGeneration &+= 1
        permissionTask?.cancel(); permissionTask = nil; requestingPermission = false
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        defaults?.set(enabled, forKey: Self.preferencesKey)
        error = nil
        if enabled, started {
            installObservers(); refresh(requestMissingPermission: true)
        } else {
            stopServices(); removeObservers()
            cancelRefresh()
            shouldRequestPermissionOnRefresh = false
            permissionGeneration &+= 1
            permissionTask?.cancel(); permissionTask = nil; requestingPermission = false
        }
    }

    func refresh(retryHotKey: Bool = true, requestMissingPermission: Bool = false) {
        guard started, enabled else { return }
        shouldRequestPermissionOnRefresh = shouldRequestPermissionOnRefresh || requestMissingPermission
        guard suspensions.isEmpty else { stopServices(); cancelRefresh(); return }
        cancelRefresh()
        checkingPermissions = true
        hotKey.setTargetPID(nil, sessionID: nil); overlay.hide()
        let current = refreshGeneration
        permissionRefreshTask = Task { [weak self] in
            guard let self else { return }
            let permissions = await self.permissionChecker.check()
            guard !Task.isCancelled, self.started, self.enabled, self.refreshGeneration == current else { return }
            self.permissionRefreshTask = nil; self.checkingPermissions = false; self.permissions = permissions
            let wasRunning = self.running
            self.applyPermissions(retryHotKey: retryHotKey)
            if wasRunning, self.running { self.backend.refresh() }
            if self.shouldRequestPermissionOnRefresh {
                self.shouldRequestPermissionOnRefresh = false
                if let first = permissions.missing.first { self.requestPermission(first) }
            }
        }
    }

    func requestPermission(_ permission: FinderJumpPermission) {
        guard started, enabled, !requestingPermission else { return }
        requestingPermission = true
        let current = permissionGeneration
        permissionTask = Task { [weak self] in
            guard let self else { return }
            await self.permissionChecker.request(permission)
            guard !Task.isCancelled, self.started, self.enabled, self.permissionGeneration == current else { return }
            self.requestingPermission = false; self.permissionTask = nil
            self.refresh()
        }
    }

    func setLauncherShortcut(_ configuration: HotKeyConfiguration) {
        let conflict = configuration.enabled && configuration.shortcut == FinderJumpHotKey.shortcut
        guard shortcutConflict != conflict else { return }
        shortcutConflict = conflict
        if started, enabled { applyPermissions() }
    }

    private func applyPermissions(retryHotKey: Bool = true) {
        guard !checkingPermissions else { synchronizePresentation(); return }
        guard started, enabled, permissions.canNavigate, suspensions.isEmpty else {
            stopServices()
            return
        }
        if !running { running = true; backend.start() }
        if shortcutConflict || !permissions.listenEvents {
            if shortcutAvailable { hotKey.stop() }
            shortcutAvailable = false
        } else if !shortcutAvailable, retryHotKey {
            do { try hotKey.start(); shortcutAvailable = true; error = nil }
            catch { self.error = error.localizedDescription }
        }
        synchronizePresentation()
    }

    private func backendChanged() {
        guard started, enabled, running else { return }
        synchronizePresentation()
    }

    private func synchronizePresentation() {
        guard started, enabled, running, !checkingPermissions, suspensions.isEmpty,
              let target = backend.target, let directory = backend.location else {
            hotKey.setTargetPID(nil, sessionID: nil); overlay.hide()
            return
        }
        hotKey.setTargetPID(shortcutAvailable && !navigating ? target.hostPID : nil,
                            sessionID: shortcutAvailable && !navigating ? target.identity + "\n" + directory.path : nil)
        overlay.show(directory: directory, target: target, shortcutAvailable: shortcutAvailable, navigating: navigating)
    }

    private func navigate() {
        guard started, enabled, running, !navigating else { return }
        guard let requestedTarget = backend.target, let requestedDirectory = backend.location else { return }
        error = nil; navigating = true
        synchronizePresentation()
        let current = generation
        navigationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let permissions = await self.permissionChecker.check()
                try Task.checkCancellation()
                guard self.generation == current, self.started, self.enabled else { return }
                self.permissions = permissions
                self.applyPermissions()
                guard self.running, self.backend.target?.identity == requestedTarget.identity,
                      self.backend.location == requestedDirectory else {
                    if self.generation == current { self.navigating = false; self.navigationTask = nil; self.synchronizePresentation() }
                    return
                }
                try await self.backend.navigate()
            }
            catch {
                if !Task.isCancelled, self.generation == current { self.error = error.localizedDescription }
            }
            guard !Task.isCancelled, self.generation == current else { return }
            self.navigating = false; self.navigationTask = nil
            self.refresh()
        }
    }

    private func cancelNavigation() {
        generation &+= 1
        navigationTask?.cancel(); navigationTask = nil; navigating = false
    }

    private func stopServices() {
        cancelNavigation()
        hotKey.setTargetPID(nil, sessionID: nil)
        if shortcutAvailable { hotKey.stop() }
        shortcutAvailable = false
        overlay.hide()
        if running { running = false; backend.stop() }
    }

    private func cancelRefresh() {
        refreshGeneration &+= 1
        permissionRefreshTask?.cancel(); permissionRefreshTask = nil
        checkingPermissions = false
    }

    private func installObservers() {
        guard observeSystemEvents, workspaceObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.cancelNavigation()
                    self?.hotKey.setTargetPID(nil, sessionID: nil); self?.overlay.hide()
                    self?.refresh()
                }
            })
        }
        let suspensions: [(Notification.Name, String, Bool)] = [
            (NSWorkspace.willSleepNotification, "sleep", true), (NSWorkspace.didWakeNotification, "sleep", false),
            (NSWorkspace.screensDidSleepNotification, "display", true), (NSWorkspace.screensDidWakeNotification, "display", false),
            (NSWorkspace.sessionDidResignActiveNotification, "session", true), (NSWorkspace.sessionDidBecomeActiveNotification, "session", false)
        ]
        for (name, reason, suspended) in suspensions {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if suspended { self.suspensions.insert(reason) } else { self.suspensions.remove(reason) }
                    self.refresh()
                }
            })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didChangeScreenParametersNotification] {
            appObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    private func removeObservers() {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.removeAll(); appObservers.removeAll(); suspensions.removeAll()
    }
}
