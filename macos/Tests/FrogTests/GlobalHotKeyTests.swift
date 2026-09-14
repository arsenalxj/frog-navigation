import AppKit
import Carbon
import XCTest
@testable import Frog

@MainActor
private final class FakeHotKeyRegistrar: HotKeyRegistering {
    var shortcut: HotKeyShortcut?
    var handler: ((Bool) -> Void)?
    var failures: Set<UInt32> = []
    var registrations = 0
    func register(_ shortcut: HotKeyShortcut, handler: @escaping (Bool) -> Void) throws {
        registrations += 1
        if failures.contains(shortcut.keyCode) { throw HotKeyRegistrationError.occupied }
        self.shortcut = shortcut; self.handler = handler
    }
    func unregister() { shortcut = nil; handler = nil }
    func send(_ pressed: Bool) { handler?(pressed) }
}

@MainActor
final class GlobalHotKeyTests: XCTestCase {
    private func layout(_ name: String) throws -> KeyboardLayout {
        let filter = [kTISPropertyInputSourceID as String: "com.apple.keylayout." + name] as CFDictionary
        let sources = TISCreateInputSourceList(filter, true).takeRetainedValue() as! [TISInputSource]
        return KeyboardLayout(source: try XCTUnwrap(sources.first, "系统键盘布局 \(name) 不存在"))
    }
    private func makeController(registrar: HotKeyRegistering, defaults: UserDefaults?,
                                validate: (@MainActor (HotKeyShortcut) -> String?)? = nil) -> GlobalHotKeyController {
        let us = try! layout("US")
        return GlobalHotKeyController(registrar: registrar, defaults: defaults, validate: validate ?? {
            $0.validationError(layout: us, menuShortcuts: ApplicationMenuCommand.defaults +
                               [MenuShortcut(key: "z", modifiers: UInt32(cmdKey | shiftKey))])
        })
    }

    private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = .option, type: NSEvent.EventType = .keyDown, repeated: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeated, keyCode: code)!
    }

    func testDefaultRegistersOnlyWhenStartedAndStopsCleanly() {
        let registrar = FakeHotKeyRegistrar()
        let controller = makeController(registrar: registrar, defaults: nil)
        XCTAssertEqual(controller.configuration, HotKeyConfiguration())
        XCTAssertNil(registrar.shortcut)
        controller.start(); controller.start()
        XCTAssertEqual(registrar.shortcut, .standard)
        XCTAssertEqual(registrar.registrations, 1)
        XCTAssertTrue(controller.registered)
        controller.stop()
        XCTAssertNil(registrar.shortcut)
        XCTAssertFalse(controller.registered)
    }

    func testConfigurationSurvivesRestartAndRestoresDefault() throws {
        let name = "Frog-HotKey-Tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = makeController(registrar: FakeHotKeyRegistrar(), defaults: defaults)
        controller.start(); controller.beginRecording(); controller.record(key(40, flags: [.control, .option]))
        XCTAssertEqual(controller.configuration.shortcut, HotKeyShortcut(keyCode: 40, modifiers: UInt32(controlKey | optionKey)))
        controller.setEnabled(false); controller.stop()
        let registrar = FakeHotKeyRegistrar()
        let restarted = makeController(registrar: registrar, defaults: defaults)
        restarted.start()
        XCTAssertFalse(restarted.configuration.enabled)
        XCTAssertEqual(restarted.configuration.shortcut, controller.configuration.shortcut)
        XCTAssertNil(registrar.shortcut)
        restarted.restoreDefault()
        XCTAssertEqual(restarted.configuration, HotKeyConfiguration())
        XCTAssertEqual(registrar.shortcut, .standard)
        restarted.stop()
        XCTAssertEqual(makeController(registrar: FakeHotKeyRegistrar(), defaults: defaults).configuration, HotKeyConfiguration())
    }

    func testIsolationDoesNotWriteStandardPreferences() {
        let before = UserDefaults.standard.object(forKey: GlobalHotKeyController.preferencesKey) as? Data
        let controller = makeController(registrar: FakeHotKeyRegistrar(), defaults: nil)
        controller.start(); controller.setEnabled(false); controller.stop()
        XCTAssertEqual(UserDefaults.standard.object(forKey: GlobalHotKeyController.preferencesKey) as? Data, before)
    }

    func testInvalidSavedConfigurationFallsBackToDefault() throws {
        let name = "Frog-HotKey-Tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(try JSONEncoder().encode(HotKeyConfiguration(enabled: true, shortcut: HotKeyShortcut(keyCode: 0, modifiers: 0))),
                     forKey: GlobalHotKeyController.preferencesKey)
        XCTAssertEqual(makeController(registrar: FakeHotKeyRegistrar(), defaults: defaults).configuration, HotKeyConfiguration())
    }

    func testConflictPreservesSavedConfigurationAndOriginalRegistration() throws {
        let name = "Frog-HotKey-Tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let registrar = FakeHotKeyRegistrar()
        let controller = makeController(registrar: registrar, defaults: defaults)
        var triggers = 0
        controller.onTrigger = { triggers += 1 }
        controller.start(); controller.restoreDefault()
        let before = defaults.data(forKey: GlobalHotKeyController.preferencesKey)
        registrar.failures = [40]
        controller.beginRecording(); controller.record(key(40))
        XCTAssertEqual(controller.configuration, HotKeyConfiguration())
        XCTAssertEqual(registrar.shortcut, .standard)
        XCTAssertEqual(defaults.data(forKey: GlobalHotKeyController.preferencesKey), before)
        XCTAssertTrue(controller.registered)
        XCTAssertTrue(controller.error?.contains("已保留原快捷键") == true)
        registrar.send(true)
        XCTAssertEqual(triggers, 1, "失败录入不应吞掉原快捷键的首次按压")
        controller.stop()
    }

    func testStartupAndRollbackFailureExposeInactiveStatusAndCanRetry() {
        let registrar = FakeHotKeyRegistrar()
        registrar.failures = [49]
        let controller = makeController(registrar: registrar, defaults: nil)
        controller.start()
        XCTAssertFalse(controller.registered)
        XCTAssertTrue(controller.configuration.enabled)
        XCTAssertNotNil(controller.error)
        registrar.failures = []
        controller.setEnabled(true)
        XCTAssertTrue(controller.registered)
        XCTAssertNil(controller.error)
        registrar.failures = [49, 40]
        controller.beginRecording(); controller.record(key(40))
        XCTAssertFalse(controller.registered)
        XCTAssertEqual(controller.configuration.shortcut, .standard)
        XCTAssertTrue(controller.error?.contains("原快捷键也未能恢复") == true)
        controller.stop()
    }

    func testRecordingSuspendsBindingAndEscapeOrCancellationRestoresIt() {
        let registrar = FakeHotKeyRegistrar()
        let controller = makeController(registrar: registrar, defaults: nil)
        controller.start(); controller.beginRecording()
        XCTAssertTrue(controller.recording); XCTAssertNil(registrar.shortcut)
        controller.record(key(53, flags: []))
        XCTAssertFalse(controller.recording); XCTAssertEqual(registrar.shortcut, .standard)
        controller.beginRecording(); controller.cancelRecording()
        XCTAssertEqual(registrar.shortcut, .standard)
        controller.setEnabled(false); controller.beginRecording(); controller.cancelRecording()
        XCTAssertNil(registrar.shortcut); XCTAssertFalse(controller.configuration.enabled)
        controller.stop()
    }

    func testInvalidRecordingAndRepeatedKeyLeaveRecordingActive() {
        let registrar = FakeHotKeyRegistrar()
        let controller = makeController(registrar: registrar, defaults: nil)
        controller.start(); controller.beginRecording()
        controller.record(key(0, flags: []))
        XCTAssertNotNil(controller.error); XCTAssertTrue(controller.recording)
        controller.record(key(43, flags: .command))
        XCTAssertTrue(controller.error?.contains("现有命令") == true)
        controller.record(key(40, repeated: true))
        XCTAssertTrue(controller.recording); XCTAssertNil(registrar.shortcut)
        controller.record(key(40))
        XCTAssertFalse(controller.recording); XCTAssertNil(controller.error)
        XCTAssertEqual(registrar.shortcut?.keyCode, 40)
        controller.stop()
    }

    func testOneTriggerPerPressAndRecordingPressIsSuppressedUntilRelease() {
        let registrar = FakeHotKeyRegistrar()
        let controller = makeController(registrar: registrar, defaults: nil)
        var triggers = 0
        controller.onTrigger = { triggers += 1 }
        controller.start()
        registrar.send(true); registrar.send(true); registrar.send(true)
        XCTAssertEqual(triggers, 1)
        registrar.send(false); registrar.send(true)
        XCTAssertEqual(triggers, 2)
        controller.beginRecording(); controller.record(key(40))
        registrar.send(true)
        XCTAssertEqual(triggers, 2)
        controller.keyReleased(key(40, type: .keyUp))
        registrar.send(true); registrar.send(false)
        XCTAssertEqual(triggers, 3)
        controller.beginRecording(); controller.record(key(49))
        registrar.send(true); registrar.send(false); registrar.send(true)
        XCTAssertEqual(triggers, 4)
        controller.stop()
    }

    func testDisabledBindingAndOldCallbackCannotTrigger() {
        let registrar = FakeHotKeyRegistrar()
        let controller = makeController(registrar: registrar, defaults: nil)
        var triggers = 0
        controller.onTrigger = { triggers += 1 }
        controller.start()
        let callback = registrar.handler
        controller.setEnabled(false)
        callback?(true)
        XCTAssertEqual(triggers, 0)
        controller.setEnabled(true)
        callback?(true)
        XCTAssertEqual(triggers, 0, "重新启用后，旧注册回调仍然失效")
        registrar.send(true)
        XCTAssertEqual(triggers, 1)
        controller.stop()
    }

    func testShortcutValidationMatchesApplicationCommands() throws {
        let us = try layout("US")
        func validate(_ shortcut: HotKeyShortcut) -> String? {
            shortcut.validationError(layout: us, menuShortcuts: ApplicationMenuCommand.defaults)
        }
        XCTAssertNil(validate(.standard))
        XCTAssertEqual(HotKeyShortcut.standard.display, "⌥Space")
        for code: UInt32 in [36, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 76, 116, 121, 128] {
            XCTAssertNotNil(validate(HotKeyShortcut(keyCode: code, modifiers: UInt32(optionKey))), "键码 \(code)")
        }
        for code: UInt32 in [0, 6, 7, 8, 9, 4, 12, 43, 45, 123, 124] {
            XCTAssertNotNil(validate(HotKeyShortcut(keyCode: code, modifiers: UInt32(cmdKey))))
        }
        XCTAssertNil(validate(HotKeyShortcut(keyCode: 40, modifiers: UInt32(controlKey | optionKey | shiftKey))))
        for code: UInt32 in [123, 124, 125, 126] {
            XCTAssertNotNil(validate(HotKeyShortcut(keyCode: code, modifiers: UInt32(controlKey))))
            XCTAssertNil(validate(HotKeyShortcut(keyCode: code, modifiers: UInt32(optionKey))))
        }
        XCTAssertNotNil(validate(HotKeyShortcut(keyCode: 40, modifiers: UInt32(shiftKey))))
    }

    func testSlashCombinationsCannotReplaceSearchFocusCommand() throws {
        let us = try layout("US")
        func validate(_ shortcut: HotKeyShortcut) -> String? {
            shortcut.validationError(layout: us, menuShortcuts: ApplicationMenuCommand.defaults)
        }
        for modifiers in [cmdKey, optionKey, controlKey] {
            XCTAssertNotNil(validate(HotKeyShortcut(keyCode: 44, modifiers: UInt32(modifiers))))
        }
    }

    func testCommandConflictsFollowGermanLayoutAndShift() throws {
        let german = try layout("German"), us = try layout("US")
        let menus = ApplicationMenuCommand.defaults + [MenuShortcut(key: "z", modifiers: UInt32(cmdKey | shiftKey))]
        XCTAssertEqual(german.characters(keyCode: 16, modifiers: UInt32(cmdKey)), "z")
        XCTAssertNotNil(HotKeyShortcut(keyCode: 16, modifiers: UInt32(cmdKey)).validationError(layout: german, menuShortcuts: menus))
        XCTAssertNotNil(HotKeyShortcut(keyCode: 16, modifiers: UInt32(cmdKey | shiftKey)).validationError(layout: german, menuShortcuts: menus))
        XCTAssertNil(HotKeyShortcut(keyCode: 16, modifiers: UInt32(cmdKey)).validationError(layout: us, menuShortcuts: menus))
        XCTAssertNil(HotKeyShortcut(keyCode: 6, modifiers: UInt32(cmdKey)).validationError(layout: german, menuShortcuts: menus))
        let slashCode = try XCTUnwrap((UInt32(0)...127).first { german.characters(keyCode: $0, modifiers: UInt32(shiftKey)) == "/" })
        XCTAssertNotNil(HotKeyShortcut(keyCode: slashCode, modifiers: UInt32(optionKey | shiftKey)).validationError(layout: german, menuShortcuts: menus))
    }

    func testActualNestedMenuBindingsIncludingDisabledCommandsAreReserved() throws {
        let menu = NSMenu(), submenu = NSMenu()
        let group = NSMenuItem(); group.submenu = submenu; menu.addItem(group)
        let command = NSMenuItem(title: "自定义应用命令", action: nil, keyEquivalent: "k")
        command.keyEquivalentModifierMask = [.control, .option]; command.isEnabled = false
        submenu.addItem(command)
        let uppercase = NSMenuItem(title: "带 Shift 的应用命令", action: nil, keyEquivalent: "K")
        submenu.addItem(uppercase)
        let bindings = MenuShortcut.shortcuts(in: menu)
        let us = try layout("US")
        XCTAssertNotNil(HotKeyShortcut(keyCode: 40, modifiers: UInt32(controlKey | optionKey)).validationError(layout: us, menuShortcuts: bindings))
        XCTAssertNotNil(HotKeyShortcut(keyCode: 40, modifiers: UInt32(cmdKey | shiftKey)).validationError(layout: us, menuShortcuts: bindings))
        XCTAssertNil(HotKeyShortcut(keyCode: 40, modifiers: UInt32(cmdKey)).validationError(layout: us, menuShortcuts: bindings))
    }

    func testLayoutChangeSuspendsConflictingBindingWithoutOverwritingPreference() throws {
        let name = "Frog-Layout-Tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var current = try layout("US")
        let registrar = FakeHotKeyRegistrar()
        let controller = makeController(registrar: registrar, defaults: defaults) {
            $0.validationError(layout: current, menuShortcuts: ApplicationMenuCommand.defaults)
        }
        controller.start(); controller.beginRecording(); controller.record(key(16, flags: .command))
        let saved = defaults.data(forKey: GlobalHotKeyController.preferencesKey)
        XCTAssertEqual(registrar.shortcut?.keyCode, 16)
        current = try layout("German"); controller.keyboardLayoutChanged()
        XCTAssertFalse(controller.registered); XCTAssertNil(registrar.shortcut)
        XCTAssertTrue(controller.error?.contains("现有命令") == true)
        XCTAssertEqual(controller.configuration.shortcut.keyCode, 16)
        XCTAssertEqual(defaults.data(forKey: GlobalHotKeyController.preferencesKey), saved)
        controller.stop()
        let restarted = makeController(registrar: registrar, defaults: defaults) {
            $0.validationError(layout: current, menuShortcuts: ApplicationMenuCommand.defaults)
        }
        restarted.start()
        XCTAssertFalse(restarted.registered); XCTAssertEqual(restarted.configuration.shortcut.keyCode, 16)
        current = try layout("US"); restarted.keyboardLayoutChanged()
        XCTAssertTrue(restarted.registered); XCTAssertNil(restarted.error)
        XCTAssertEqual(defaults.data(forKey: GlobalHotKeyController.preferencesKey), saved)
        current = try layout("German"); restarted.keyboardLayoutChanged(); restarted.setEnabled(false)
        XCTAssertFalse(restarted.configuration.enabled); XCTAssertNil(restarted.error)
        restarted.stop()
    }

    func testLayoutChangeDuringRecordingKeepsOriginalBindingSuspended() throws {
        var current = try layout("US")
        let registrar = FakeHotKeyRegistrar()
        let controller = makeController(registrar: registrar, defaults: nil) {
            $0.validationError(layout: current, menuShortcuts: ApplicationMenuCommand.defaults)
        }
        controller.start(); controller.beginRecording()
        current = try layout("German"); controller.keyboardLayoutChanged()
        XCTAssertTrue(controller.recording); XCTAssertNil(registrar.shortcut)
        controller.record(key(16, flags: .command))
        XCTAssertTrue(controller.recording); XCTAssertNotNil(controller.error)
        controller.cancelRecording()
        XCTAssertEqual(registrar.shortcut, .standard)
        controller.stop()
    }

    func testSilentStartupRetainsEarlyRequestWithoutCreatingWindowPrematurely() {
        var activation = LauncherActivationState()
        XCTAssertEqual(activation.toggle(presented: false, applicationHidden: false, systemPanelActive: false), .none)
        XCTAssertFalse(activation.loaded)
        XCTAssertTrue(activation.finishLoading(silently: true))
        XCTAssertTrue(activation.loaded)
        var silent = LauncherActivationState()
        XCTAssertFalse(silent.finishLoading(silently: true))
        var manual = LauncherActivationState()
        XCTAssertTrue(manual.finishLoading(silently: false))
    }

    func testToggleUsesPresentationTargetSoFastPressesReverseAnimationAndUnhideWorks() {
        var activation = LauncherActivationState()
        _ = activation.finishLoading(silently: true)
        XCTAssertEqual(activation.toggle(presented: false, applicationHidden: false, systemPanelActive: false), .show)
        XCTAssertEqual(activation.toggle(presented: true, applicationHidden: false, systemPanelActive: false), .hide)
        XCTAssertEqual(activation.toggle(presented: false, applicationHidden: false, systemPanelActive: false), .show)
        XCTAssertEqual(activation.toggle(presented: true, applicationHidden: true, systemPanelActive: false), .show)
        XCTAssertEqual(activation.toggle(presented: false, applicationHidden: true, systemPanelActive: true), .none)
        XCTAssertEqual(activation.toggle(presented: true, applicationHidden: false, systemPanelActive: true), .none)
    }
}
