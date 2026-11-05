import AppKit
import FrogCore
import Carbon
import Combine

@main
struct FrogApplication {
    static func main() {
        Diagnostics.emit("process_started")
        let application = NSApplication.shared
        let delegate = ApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var launcher: LauncherWindowController?
    private var store: BookmarkStore!
    private var model: LauncherModel!
    private var activation = LauncherActivationState()
    private var hotKey: GlobalHotKeyController!
    private var hotCorner: HotCornerController!
    private var finderJump: FinderJumpController!
    private var finderJumpShortcutSubscription: AnyCancellable?
    private var pendingCornerScreenID: UInt32?
    private var keyboardLayoutObserver: NSObjectProtocol?
    private var launchSilently = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        let directoryIndex = arguments.firstIndex(of: "--data-directory")
        let override = directoryIndex.flatMap { $0 + 1 < arguments.count ? URL(fileURLWithPath: arguments[$0 + 1], isDirectory: true) : nil }
        store = BookmarkStore(directoryOverride: override, persistDirectory: override == nil)
        hotKey = GlobalHotKeyController(registrar: CarbonHotKeyRegistrar(), defaults: override == nil ? .standard : nil)
        hotCorner = HotCornerController(source: NativeHotCornerMonitor(), defaults: override == nil ? .standard : nil)
        finderJump = FinderJumpController(defaults: override == nil ? .standard : nil)
        model = LauncherModel(store: store, isolated: override != nil,
                              hotKey: hotKey, hotCorner: hotCorner, finderJump: finderJump)
        launchSilently = arguments.contains("--background") ||
            NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        installMenu()
        hotKey.onTrigger = { [weak self] in self?.toggleLauncher() }
        hotKey.start()
        finderJumpShortcutSubscription = hotKey.$configuration.sink { [weak self] configuration in
            self?.finderJump.setLauncherShortcut(configuration)
        }
        finderJump.start()
        keyboardLayoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hotKey.keyboardLayoutChanged() }
        }
        hotCorner.canTrigger = { [weak self] in
            guard let self else { return false }
            return LauncherActivationState.allowsCorner(visible: self.model.visible, presented: self.model.presented,
                                                       systemPanelActive: self.launcher?.systemPanelActive == true)
        }
        hotCorner.onTrigger = { [weak self] screen in self?.openFromCorner(screen) }
        hotCorner.start()
        Task {
            await store.load()
            Diagnostics.emit("data_loaded")
            if activation.finishLoading(silently: launchSilently) { showLauncher(on: pendingCornerScreenID) }
            pendingCornerScreenID = nil
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launchSilently = false
        pendingCornerScreenID = nil
        if activation.loaded { showLauncher() }
        return false
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard activation.loaded else { return }
        model.login.refresh()
        Task { await store.reloadIfChanged() }
    }
    func applicationDidResignActive(_ notification: Notification) {
        hotKey?.cancelRecording()
        guard let launcher, !launcher.systemPanelActive else { return }
        launcher.hideLauncher(restorePreviousApplication: false)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        if let keyboardLayoutObserver { DistributedNotificationCenter.default().removeObserver(keyboardLayoutObserver) }
        finderJumpShortcutSubscription?.cancel()
        finderJump?.stop(); hotKey?.stop(); hotCorner?.stop()
    }
    private func toggleLauncher() {
        pendingCornerScreenID = nil
        let action = activation.toggle(presented: model.presented, applicationHidden: NSApp.isHidden,
                                       systemPanelActive: launcher?.systemPanelActive == true)
        Diagnostics.emit("hotkey_triggered", details: ["action": String(describing: action)])
        switch action {
        case .none: break
        case .show: showLauncher()
        case .hide: launcher?.hideLauncher()
        }
    }
    private func openFromCorner(_ screen: HotCornerScreen) {
        Diagnostics.emit("hotcorner_triggered", details: ["corner": hotCorner.configuration.corner.rawValue, "screen_id": screen.id])
        if activation.requestShow() { showLauncher(on: screen.id) }
        else { pendingCornerScreenID = screen.id }
    }
    private func showLauncher(on screenID: UInt32? = nil) {
        if launcher == nil { launcher = LauncherWindowController(model: model) }
        launcher?.showLauncher(on: screenID)
    }
    @objc private func openSettings() { showLauncher(); model.openSettings() }
    @objc private func addBookmark() { showLauncher(); model.addBookmark() }
    private func installMenu() {
        let menu = NSMenu()
        let app = NSMenuItem(); let appMenu = NSMenu(title: "青蛙导航")
        let settings = ApplicationMenuCommand.settings.menuItem(target: self)
        appMenu.addItem(settings); appMenu.addItem(.separator())
        let hide = ApplicationMenuCommand.hide.menuItem()
        appMenu.addItem(hide)
        let quit = ApplicationMenuCommand.quit.menuItem()
        appMenu.addItem(quit); app.submenu = appMenu; menu.addItem(app)
        let file = NSMenuItem(); let fileMenu = NSMenu(title: "文件")
        let add = ApplicationMenuCommand.add.menuItem(target: self)
        fileMenu.addItem(add); file.submenu = fileMenu; menu.addItem(file)
        let edit = NSMenuItem(); let editMenu = NSMenu(title: "编辑")
        for command in ApplicationMenuCommand.editing {
            editMenu.addItem(command.menuItem())
        }
        edit.submenu = editMenu; menu.addItem(edit)
        NSApp.mainMenu = menu
    }
}

final class LauncherWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    var willResignKey: (() -> Void)?
    override func resignKey() { willResignKey?(); super.resignKey() }
}

@MainActor
final class LauncherWindowController: NSWindowController {
    private let model: LauncherModel
    private let terminalView: LauncherView
    private var eventMonitor: Any?
    private var displayObserver: NSObjectProtocol?
    private var menuObservers: [NSObjectProtocol] = []
    private var menuTracking = 0
    private var hasShown = false
    private var screenPlacement = LauncherScreenPlacement()
    var systemPanelActive: Bool { NSApp.modalWindow != nil || window?.attachedSheet != nil }

    init(model: LauncherModel) {
        self.model = model
        terminalView = LauncherView(model: model)
        let window = LauncherWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        window.title = "青蛙导航"
        window.isOpaque = true
        window.backgroundColor = NSColor(srgbRed: 1, green: 254.0 / 255, blue: 248.0 / 255, alpha: 1)
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        // 高于菜单栏（24）与程序坞（20），因此界面可铺满整块屏幕；收起后菜单栏与程序坞照常显示。
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        window.animationBehavior = .none
        window.acceptsMouseMovedEvents = true
        terminalView.autoresizingMask = [.width, .height]
        window.contentView = terminalView
        super.init(window: window)
        window.willResignKey = { [weak self] in self?.terminalView.prepareForHide() }
        model.dismissWindow = { [weak self] in self?.hideLauncher() }
        model.terminateApplication = { NSApp.terminate(nil) }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown]) { [weak self] event in
            if event.type == .keyUp { model.hotKey?.keyReleased(event); return event }
            guard let self, model.visible, !self.systemPanelActive,
                  event.window === self.window else { return event }
            if model.hotKey?.recording == true {
                if event.type == .keyDown { model.hotKey?.record(event); return nil }
                if event.type == .leftMouseDown { model.hotKey?.cancelRecording() }
            }
            guard event.type == .keyDown, self.menuTracking == 0 else { return event }
            return LauncherKeyRouter.handle(event, model: model, firstResponder: self.window?.firstResponder) ? nil : event
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.model.visible == true { self?.positionOnScreen() }
            }
        }
        menuObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking += 1; self?.terminalView.prepareForHide() }
        })
        menuObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuTracking = max(0, self.menuTracking - 1)
                if self.model.visible { self.terminalView.restoreFocus() }
            }
        })
    }

    required init?(coder: NSCoder) { fatalError("仅支持程序化创建窗口") }

    func showLauncher(on screenID: UInt32? = nil) {
        guard let window else { return }
        if model.visible && model.presented && !NSApp.isHidden && NSApp.isActive {
            window.makeKeyAndOrderFront(nil)
            terminalView.restoreFocus()
            return
        }
        let showStarted = ProcessInfo.processInfo.systemUptime
        let first = !hasShown
        hasShown = true
        positionOnScreen(displayID: screenID)
        model.visible = true
        model.presented = true
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.visible else { return }
            self.window?.contentView?.layoutSubtreeIfNeeded()
            self.terminalView.restoreFocus()
            self.window?.displayIfNeeded()
            Diagnostics.emit(first ? "first_interactive" : "expand_interactive", since: first ? nil : showStarted)
        }
        Task { await model.store.reloadIfChanged() }
    }

    func hideLauncher(restorePreviousApplication: Bool = true) {
        guard model.visible, !systemPanelActive else { return }
        terminalView.prepareForHide()
        model.hotKey?.cancelRecording()
        model.didHide()
        window?.orderOut(nil)
        if restorePreviousApplication && NSApp.isActive { NSApp.hide(nil) }
        Diagnostics.emit("did_hide")
    }

    private func positionOnScreen(displayID: UInt32? = nil) {
        let screens = NSScreen.screens
        guard let target = screenPlacement.update(visible: model.visible, requestedID: displayID, mouse: NSEvent.mouseLocation,
                                                  displays: screens.compactMap { LauncherDisplay($0) },
                                                  fallbackID: NSScreen.main.flatMap { LauncherDisplay($0) }?.id),
              let screen = screens.first(where: { LauncherDisplay($0)?.id == target.id }) else { return }
        // 铺满整块屏幕，连菜单栏与程序坞区域一并覆盖。
        window?.setFrame(screen.frame, display: true)
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
    }
}

@MainActor
enum LauncherKeyRouter {
    static func handle(_ event: NSEvent, model: LauncherModel, firstResponder: NSResponder?) -> Bool {
        // 中文组字的确认、取消与候选移动先交给系统输入法。
        if let input = firstResponder as? NSTextInputClient, input.hasMarkedText() { return false }
        return model.handleKey(event, isTextEditing: firstResponder is NSTextView)
    }
}
