import AppKit
import Carbon

struct KeyboardLayout {
    private let data: CFData?
    private let keyboardType: UInt32

    init(source: TISInputSource, keyboardType: UInt32 = UInt32(LMGetKbdType())) {
        self.keyboardType = keyboardType
        data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData).map {
            Unmanaged<CFData>.fromOpaque($0).takeUnretainedValue()
        }
    }

    static var current: KeyboardLayout? {
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() {
            let layout = KeyboardLayout(source: source)
            if layout.data != nil { return layout }
        }
        return (TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()).map { KeyboardLayout(source: $0) }
    }

    func characters(keyCode: UInt32, modifiers: UInt32) -> String? {
        guard let data, keyCode <= 127 else { return nil }
        let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKey: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        // 保留 Shift 和 Command 对字符的影响（包括 Dvorak-QWERTY Command 布局）。
        let flags = (modifiers & UInt32(cmdKey | shiftKey)) >> 8
        let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown), flags, keyboardType,
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKey, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

struct MenuShortcut {
    let key: String
    var modifiers = UInt32(cmdKey)

    func matches(characters: String, modifiers: UInt32) -> Bool {
        let required = self.modifiers | (key != key.lowercased() ? UInt32(shiftKey) : 0)
        return modifiers == required && characters.lowercased() == key.lowercased()
    }

    @MainActor
    static func shortcuts(in menu: NSMenu) -> [MenuShortcut] {
        menu.items.flatMap { item -> [MenuShortcut] in
            if let submenu = item.submenu { return shortcuts(in: submenu) }
            guard !item.keyEquivalent.isEmpty else { return [] }
            return [MenuShortcut(key: item.keyEquivalent, modifiers: HotKeyShortcut.carbonModifiers(item.keyEquivalentModifierMask))]
        }
    }
}

struct ApplicationMenuCommand {
    let title: String
    let action: String
    let key: String
    static let settings = ApplicationMenuCommand(title: "设置…", action: "openSettings", key: ",")
    static let hide = ApplicationMenuCommand(title: "隐藏青蛙导航", action: "hide:", key: "h")
    static let quit = ApplicationMenuCommand(title: "退出青蛙导航", action: "terminate:", key: "q")
    static let add = ApplicationMenuCommand(title: "添加书签…", action: "addBookmark", key: "n")
    static let editing = [
        ApplicationMenuCommand(title: "撤销", action: "undo:", key: "z"),
        ApplicationMenuCommand(title: "剪切", action: "cut:", key: "x"),
        ApplicationMenuCommand(title: "复制", action: "copy:", key: "c"),
        ApplicationMenuCommand(title: "粘贴", action: "paste:", key: "v"),
        ApplicationMenuCommand(title: "全选", action: "selectAll:", key: "a")
    ]
    static var defaults: [MenuShortcut] { ([settings, hide, quit, add] + editing).map { MenuShortcut(key: $0.key) } }

    @MainActor
    static var reservedShortcuts: [MenuShortcut] {
        // 文本控件也提供 Shift-Command-Z 重做，即使菜单没有单列该项。
        (NSApp?.mainMenu.map { MenuShortcut.shortcuts(in: $0) } ?? defaults) + [MenuShortcut(key: "z", modifiers: UInt32(cmdKey | shiftKey))]
    }

    @MainActor
    func menuItem(target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
        item.target = target
        return item
    }
}

enum LauncherKeyboardCommand: Equatable {
    case escape, settings, previousPage, nextPage, moveSelection, activate, focusSearch

    static func match(keyCode: UInt32, modifiers: UInt32, characters: String?) -> LauncherKeyboardCommand? {
        let command = modifiers & UInt32(cmdKey) != 0
        if keyCode == 53 { return .escape }
        if command, characters == "," { return .settings }
        if command, keyCode == 123 { return .previousPage }
        if command, keyCode == 124 { return .nextPage }
        if keyCode == 116 { return .previousPage }
        if keyCode == 121 { return .nextPage }
        if [123, 124, 125, 126].contains(keyCode), !command, modifiers & UInt32(optionKey) == 0 { return .moveSelection }
        if keyCode == 36 || keyCode == 76 { return .activate }
        if characters == "/" { return .focusSearch }
        return nil
    }
}
