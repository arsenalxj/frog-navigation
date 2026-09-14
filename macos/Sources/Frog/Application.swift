import AppKit
import FrogCore
import FrogIcons
import Carbon
import Combine
import SwiftUI

@main
struct FrogApplication {
    static func main() {
        Diagnostics.emit("process_started")
        let application = NSApplication.shared
        let delegate = ApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
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
        model = LauncherModel(store: store, icons: IconStore(networkingEnabled: !arguments.contains("--offline")), isolated: override != nil,
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
        finderJump?.stop(); hotKey?.stop(); hotCorner?.stop(); launcher?.restorePresentation()
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
    @objc private func openSettings() { showLauncher(); model.showSettings = true }
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
    var handleScroll: ((NSEvent) -> Void)?
    var willResignKey: (() -> Void)?
    var willChangeFirstResponder: (() -> Void)?
    override func scrollWheel(with event: NSEvent) { handleScroll?(event) }
    override func resignKey() { willResignKey?(); super.resignKey() }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        willChangeFirstResponder?()
        return super.makeFirstResponder(responder)
    }
}

@MainActor
final class LauncherWindowController: NSWindowController {
    private let model: LauncherModel
    private var eventMonitor: Any?
    private var displayObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var menuObservers: [NSObjectProtocol] = []
    private var menuTracking = 0
    private var wallpaperTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var previousPresentation: NSApplication.PresentationOptions?
    private var hasShown = false
    private var screenPlacement = LauncherScreenPlacement()
    private weak var savedPanelResponder: NSView?
    private var savedPanelSelection: NSRange?
    private var panelFocusPending = false
    private var panelFocusApplied = false
    private var focusObserver: NSObjectProtocol?
    var systemPanelActive = false

    init(model: LauncherModel) {
        self.model = model
        let window = LauncherWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        window.title = "青蛙导航"
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.isReleasedWhenClosed = false; window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        window.animationBehavior = .none
        window.acceptsMouseMovedEvents = true
        let hosting = NSHostingController(rootView: LauncherView(model: model, store: model.store))
        window.contentViewController = hosting
        super.init(window: window)
        window.handleScroll = { [weak model] event in model?.scroll(event) }
        window.willResignKey = { [weak self] in self?.capturePanelFocus() }
        window.willChangeFirstResponder = { [weak self] in self?.capturePanelFocus() }
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restorePanelFocusIfNeeded() }
        }
        model.dismissWindow = { [weak self] in self?.hideLauncher() }
        model.withSystemPanel = { [weak self] in self?.systemPanelActive = $0 }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            if event.type == .keyUp { model.hotKey?.keyReleased(event); return event }
            guard let self, model.visible, !self.systemPanelActive else { return event }
            if model.hotKey?.recording == true {
                if event.type == .keyDown { model.hotKey?.record(event); return nil }
                if event.type == .leftMouseDown {
                    if let recorder = self.window?.firstResponder as? HotKeyRecorderButton,
                       event.window === recorder.window, recorder.bounds.contains(recorder.convert(event.locationInWindow, from: nil)) {
                        return event
                    }
                    model.hotKey?.cancelRecording()
                }
            }
            if self.menuTracking > 0 { return event }
            if event.type == .leftMouseDown || event.type == .leftMouseDragged || event.type == .leftMouseUp {
                let point = CGPoint(x: event.locationInWindow.x, y: model.metrics.size.height - event.locationInWindow.y)
                if event.type == .leftMouseDown { model.pointerDown(at: point) }
                else if event.type == .leftMouseDragged { model.pointerDragged(to: point) }
                else { model.pointerUp(at: point) }
                return event
            }
            if event.type == .scrollWheel {
                if !model.modalVisible { model.scroll(event); return nil }
                return event
            }
            return self.handleKey(event) ? nil : event
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.model.visible == true { self?.positionOnScreen() } }
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak model] _ in
            Task { @MainActor in
                model?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                model?.reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            }
        }
        menuObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking += 1; self?.model.cancelDrag() }
        })
        menuObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.menuTracking = max(0, self.menuTracking - 1) } }
        })
    }
    required init?(coder: NSCoder) { fatalError("仅支持程序化创建窗口") }

    func showLauncher(on screenID: UInt32? = nil) {
        guard let window else { return }
        if model.visible && model.presented && !NSApp.isHidden && NSApp.isActive {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let showStarted = ProcessInfo.processInfo.systemUptime
        let first = !hasShown
        hasShown = true
        hideTask?.cancel()
        positionOnScreen(displayID: screenID)
        if previousPresentation == nil { previousPresentation = NSApp.presentationOptions }
        // AppKit requires hiding the Dock when hiding the menu bar. Keeping the real Dock
        // available takes precedence, so the user's presentation options are preserved.
        panelFocusPending = model.modalVisible && savedPanelResponder != nil
        panelFocusApplied = false
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.visible = true
        withAnimation(model.animation) { model.presented = true }
        if !model.modalVisible { savedPanelResponder = nil; savedPanelSelection = nil; model.focusRequest += 1 }
        DispatchQueue.main.async {
            window.contentView?.layoutSubtreeIfNeeded()
            self.restorePanelFocusIfNeeded()
            Diagnostics.emit(first ? "first_interactive" : "expand_interactive", since: first ? nil : showStarted)
        }
        Task { await model.store.reloadIfChanged() }
    }
    func hideLauncher(restorePreviousApplication: Bool = true) {
        guard model.visible, !systemPanelActive else { return }
        panelFocusPending = false
        capturePanelFocus()
        model.hotKey?.cancelRecording()
        hideTask?.cancel()
        withAnimation(model.animation) { model.presented = false }
        hideTask = Task {
            do { try await Task.sleep(for: .milliseconds(model.reduceMotion ? 100 : 180)) } catch { return }
            window?.orderOut(nil); restorePresentation(); model.didHide()
            if restorePreviousApplication && NSApp.isActive { NSApp.hide(nil) }
            Diagnostics.emit("did_hide")
        }
    }
    func restorePresentation() {
        if let previousPresentation { NSApp.presentationOptions = previousPresentation; self.previousPresentation = nil }
    }
    private func capturePanelFocus() {
        guard !panelFocusPending else { return }
        guard model.modalVisible, let window else { savedPanelResponder = nil; savedPanelSelection = nil; return }
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            func findControl(_ view: NSView) -> NSControl? {
                if let control = view as? NSControl, control.currentEditor() === editor { return control }
                return view.subviews.lazy.compactMap(findControl).first
            }
            if let content = window.contentView, let control = findControl(content) {
                savedPanelResponder = control; savedPanelSelection = editor.selectedRange()
            }
        } else if let responder = window.firstResponder as? NSView, responder !== window.contentView {
            savedPanelResponder = responder; savedPanelSelection = nil
        }
    }
    private func restorePanelFocusIfNeeded() {
        guard panelFocusPending, model.presented, model.modalVisible, let window, window.isKeyWindow else { return }
        guard let responder = savedPanelResponder, responder.window === window, !responder.isHiddenOrHasHiddenAncestor else {
            panelFocusPending = false; return
        }
        let editor = (responder as? NSControl)?.currentEditor()
        let focused = window.firstResponder === responder || (editor != nil && window.firstResponder === editor)
        // SwiftUI 可能在本轮布局之后释放旧焦点；到后续窗口更新确认成功才结束恢复。
        if panelFocusApplied && focused {
            if let editor = editor as? NSTextView, let selection = savedPanelSelection {
                let length = (editor.string as NSString).length
                let start = min(selection.location, length)
                editor.setSelectedRange(NSRange(location: start, length: min(selection.length, length - start)))
            }
            panelFocusPending = false
            Diagnostics.emit("panel_focus_restored")
        } else {
            panelFocusApplied = window.makeFirstResponder(responder)
            if !panelFocusApplied { panelFocusPending = false }
        }
    }
    private func positionOnScreen(displayID: UInt32? = nil) {
        let screens = NSScreen.screens
        guard let target = screenPlacement.update(visible: model.visible, requestedID: displayID, mouse: NSEvent.mouseLocation,
                                                  displays: screens.compactMap { LauncherDisplay($0) },
                                                  fallbackID: NSScreen.main.flatMap { LauncherDisplay($0) }?.id),
              let screen = screens.first(where: { LauncherDisplay($0)?.id == target.id }) else { return }
        window?.setFrame(screen.frame, display: true)
        let visible = screen.visibleFrame
        model.screenChanged(size: screen.frame.size, dockInsets: DockInsets(
            left: max(0, visible.minX - screen.frame.minX),
            right: max(0, screen.frame.maxX - visible.maxX),
            bottom: max(0, visible.minY - screen.frame.minY)))
        wallpaperTask?.cancel()
        wallpaperTask = Task {
            let wallpaper = await WallpaperLoader.load(for: screen)
            if !Task.isCancelled { model.wallpaper = wallpaper }
        }
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        LauncherKeyRouter.handle(event, model: model, firstResponder: window?.firstResponder)
    }
}

@MainActor
enum LauncherKeyRouter {
    static func handle(_ event: NSEvent, model: LauncherModel, firstResponder: NSResponder?) -> Bool {
        // NSTextView 通过 NSTextInputClient 暴露尚未提交的组字；先交给原生输入系统。
        if let input = firstResponder as? NSTextInputClient, input.hasMarkedText() { return false }
        let shortcut = HotKeyShortcut(event: event)
        let keyCommand = LauncherKeyboardCommand.match(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers,
                                                       characters: event.charactersIgnoringModifiers)
        if keyCommand == .escape { model.escape(); return true }
        let command = event.modifierFlags.contains(.command)
        if keyCommand == .settings { model.showSettings = true; return true }
        guard !model.modalVisible else { return false }
        if keyCommand == .previousPage { model.changePage(-1); return true }
        if keyCommand == .nextPage { model.changePage(1); return true }
        if keyCommand == .moveSelection {
            let direction = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : event.keyCode == 125 ? model.activeColumns : -model.activeColumns
            model.select(direction: direction); return true
        }
        if keyCommand == .activate {
            if let id = model.selection, let item = model.activeItems.first(where: { $0.id == id }) { model.activate(item) }
            else { model.submitSearch() }
            return true
        }
        if keyCommand == .focusSearch, !(firstResponder is NSTextView) { model.focusRequest += 1; return true }
        if !command, !(firstResponder is NSTextView), let characters = event.characters,
           !characters.isEmpty, characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) {
            model.query += characters
            model.focusRequest += 1
            return true
        }
        return false
    }
}
