import AppKit
import Carbon
import Combine

struct HotKeyShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    static let standard = HotKeyShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
    static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    init(event: NSEvent) {
        self.init(keyCode: UInt32(event.keyCode), modifiers: Self.carbonModifiers(event.modifierFlags))
    }

    static func carbonModifiers(_ modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    var inputValidationError: String? {
        guard keyCode <= 127, ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode),
              modifiers & ~Self.modifierMask == 0 else { return "请选择普通按键与修饰键的组合。" }
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else {
            return "请至少搭配 ⌘、⌥ 或 ⌃ 中的一个键。"
        }
        return nil
    }

    @MainActor var validationError: String? {
        validationError(layout: .current, menuShortcuts: ApplicationMenuCommand.reservedShortcuts)
    }

    func validationError(layout: KeyboardLayout?, menuShortcuts: [MenuShortcut]) -> String? {
        if let error = inputValidationError { return error }
        let characters = layout?.characters(keyCode: keyCode, modifiers: modifiers)
        if LauncherKeyboardCommand.match(keyCode: keyCode, modifiers: modifiers, characters: characters) != nil ||
            menuShortcuts.contains(where: { $0.matches(characters: characters ?? "", modifiers: modifiers) }) {
            return "此组合用于青蛙导航的现有命令，请更换快捷键。"
        }
        if characters == nil { return "暂时无法读取此按键的键盘布局，请重试或更换组合。" }
        return nil
    }

    var display: String {
        var prefix = ""
        for (flag, symbol) in [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")] {
            if modifiers & UInt32(flag) != 0 { prefix += symbol }
        }
        return prefix + keyLabel
    }

    private var keyLabel: String {
        let special: [UInt32: String] = [48: "Tab", 49: "Space", 51: "⌫", 117: "⌦", 115: "Home", 119: "End",
                                       123: "←", 124: "→", 125: "↓", 126: "↑",
                                       122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
                                       98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
                                       105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
        if let label = special[keyCode] { return label }
        if let label = KeyboardLayout.current?.characters(keyCode: keyCode, modifiers: modifiers & UInt32(cmdKey)) { return label.uppercased() }
        return "键 \(keyCode)"
    }
}

struct HotKeyConfiguration: Codable, Equatable {
    var enabled = true
    var shortcut = HotKeyShortcut.standard
}

enum HotKeyRegistrationError: LocalizedError {
    case systemConflict, occupied, system(OSStatus)
    var errorDescription: String? {
        switch self {
        case .systemConflict: return "此组合已用于系统快捷键，请更换组合或先在系统设置中调整。"
        case .occupied: return "此组合已被系统或其他应用占用，请更换快捷键。"
        case .system(let status): return "系统未能注册快捷键（\(status)），请重试或更换组合。"
        }
    }
}

@MainActor
protocol HotKeyRegistering: AnyObject {
    func register(_ shortcut: HotKeyShortcut, handler: @escaping (Bool) -> Void) throws
    func unregister()
}

@MainActor
final class CarbonHotKeyRegistrar: HotKeyRegistering {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var callback: ((Bool) -> Void)?
    private var identifier: UInt32 = 0
    private let signature: OSType = 0x41525067 // ARPg

    func register(_ shortcut: HotKeyShortcut, handler: @escaping (Bool) -> Void) throws {
        var symbolicKeys: Unmanaged<CFArray>?
        let queryStatus = CopySymbolicHotKeys(&symbolicKeys)
        guard queryStatus == noErr else { throw HotKeyRegistrationError.system(queryStatus) }
        if let keys = symbolicKeys?.takeRetainedValue() as? [[String: Any]], keys.contains(where: {
            ($0[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true &&
            ($0[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == shortcut.keyCode &&
            (($0[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value ?? 0) & HotKeyShortcut.modifierMask == shortcut.modifiers
        }) { throw HotKeyRegistrationError.systemConflict }

        unregister()
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(context).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                               nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard result == noErr, hotKeyID.signature == registrar.signature, hotKeyID.id == registrar.identifier else {
                    return OSStatus(eventNotHandledErr)
                }
                registrar.callback?(GetEventKind(event) == UInt32(kEventHotKeyPressed))
                return noErr
            }
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else { throw HotKeyRegistrationError.system(status) }
        identifier &+= 1
        callback = handler
        let registration = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                               EventHotKeyID(signature: signature, id: identifier), GetApplicationEventTarget(),
                                               OptionBits(kEventHotKeyExclusive), &hotKey)
        guard registration == noErr else {
            unregister()
            throw registration == eventHotKeyExistsErr ? HotKeyRegistrationError.occupied : HotKeyRegistrationError.system(registration)
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
        callback = nil
    }
}

@MainActor
final class GlobalHotKeyController: ObservableObject {
    static let preferencesKey = "globalHotKey"
    @Published private(set) var configuration: HotKeyConfiguration
    @Published private(set) var registered = false
    @Published private(set) var recording = false
    @Published private(set) var error: String?
    private let registrar: HotKeyRegistering
    private let defaults: UserDefaults?
    private let validate: @MainActor (HotKeyShortcut) -> String?
    private var started = false
    private var held = false
    private var suppressUntilRelease = false
    private var registrationGeneration = 0
    var onTrigger: (() -> Void)?

    init(registrar: HotKeyRegistering, defaults: UserDefaults? = .standard,
         validate: @escaping @MainActor (HotKeyShortcut) -> String? = { $0.validationError }) {
        self.registrar = registrar; self.defaults = defaults; self.validate = validate
        if let data = defaults?.data(forKey: Self.preferencesKey),
           let saved = try? JSONDecoder().decode(HotKeyConfiguration.self, from: data), saved.shortcut.inputValidationError == nil {
            configuration = saved
        } else { configuration = HotKeyConfiguration() }
    }

    func start() {
        guard !started else { return }
        started = true
        restoreRegistration()
    }
    func stop() {
        recording = false; started = false
        unregister()
    }
    func setEnabled(_ enabled: Bool) { change(HotKeyConfiguration(enabled: enabled, shortcut: configuration.shortcut)) }
    func restoreDefault() { change(HotKeyConfiguration()) }

    func keyboardLayoutChanged() {
        if !recording { restoreRegistration() }
        objectWillChange.send()
    }

    func beginRecording() {
        guard started else { return }
        unregister(); error = nil; recording = true
    }
    func cancelRecording() {
        guard recording else { return }
        recording = false
        restoreRegistration()
    }
    func record(_ event: NSEvent) {
        guard recording, event.type == .keyDown, !event.isARepeat else { return }
        if event.keyCode == 53 { cancelRecording(); return }
        let shortcut = HotKeyShortcut(event: event)
        if let reason = validate(shortcut) { error = reason; return }
        // 新组合仍被按住时，不把录入本身当成一次唤起。
        suppressUntilRelease = true
        change(HotKeyConfiguration(enabled: true, shortcut: shortcut), fromRecording: true)
    }
    func keyReleased(_ event: NSEvent) {
        if event.type == .keyUp, UInt32(event.keyCode) == configuration.shortcut.keyCode { suppressUntilRelease = false; held = false }
    }

    private func change(_ candidate: HotKeyConfiguration, fromRecording: Bool = false) {
        if candidate.enabled, let reason = validate(candidate.shortcut) { error = reason; return }
        recording = false
        let previous = configuration
        unregister(resetSuppression: !fromRecording)
        do {
            if started && candidate.enabled { try register(candidate.shortcut) }
            configuration = candidate
            error = nil
            if let data = try? JSONEncoder().encode(candidate) { defaults?.set(data, forKey: Self.preferencesKey) }
        } catch {
            suppressUntilRelease = false
            let failure = error.localizedDescription
            if started && previous.enabled {
                do { try register(previous.shortcut); self.error = failure + " 已保留原快捷键。" }
                catch { self.error = failure + " 原快捷键也未能恢复，请重新设置。" }
            } else { self.error = failure }
        }
    }
    private func register(_ shortcut: HotKeyShortcut) throws {
        if let reason = validate(shortcut) { throw ShortcutConflict(reason: reason) }
        let generation = registrationGeneration
        try registrar.register(shortcut) { [weak self] pressed in
            guard let self, self.registrationGeneration == generation else { return }
            self.receive(pressed: pressed)
        }
        registered = true
    }
    private func unregister(resetSuppression: Bool = true) {
        registrationGeneration &+= 1
        registrar.unregister(); registered = false; held = false
        if resetSuppression { suppressUntilRelease = false }
    }
    private func restoreRegistration() {
        unregister()
        error = nil
        guard started && configuration.enabled else { return }
        do { try register(configuration.shortcut) }
        catch { self.error = error.localizedDescription }
    }
    private func receive(pressed: Bool) {
        guard started, registered, !recording else { return }
        if !pressed { held = false; suppressUntilRelease = false; return }
        guard !held, !suppressUntilRelease else { return }
        held = true
        onTrigger?()
    }

    private struct ShortcutConflict: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }
}

struct LauncherActivationState {
    enum Action: Equatable { case none, show, hide }
    private(set) var loaded = false
    private var pendingShow = false
    static func allowsCorner(visible: Bool, presented: Bool, systemPanelActive: Bool) -> Bool {
        !visible && !presented && !systemPanelActive
    }
    mutating func requestShow() -> Bool {
        guard loaded else { pendingShow = true; return false }
        return true
    }
    mutating func toggle(presented: Bool, applicationHidden: Bool, systemPanelActive: Bool) -> Action {
        guard !systemPanelActive else { return .none }
        guard loaded else { pendingShow = true; return .none }
        return presented && !applicationHidden ? .hide : .show
    }
    mutating func finishLoading(silently: Bool) -> Bool {
        loaded = true
        let show = pendingShow || !silently
        pendingShow = false
        return show
    }
}
