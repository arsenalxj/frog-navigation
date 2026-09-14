import AppKit
import ApplicationServices

enum FinderJumpNavigationError: LocalizedError {
    case unavailable, changedFocus, accessibilityBusy, missingDirectory, unsupportedPanel, timedOut, cannotWritePath, unverifiedDirectory
    var errorDescription: String? {
        switch self {
        case .unavailable: return "当前没有可跳转的文件窗口或 Finder 目录。"
        case .changedFocus: return "文件窗口或焦点已变化，已停止目录跳转。"
        case .accessibilityBusy: return "文件窗口暂时无法读取，请重试。"
        case .missingDirectory: return "Finder 目录已不可用。"
        case .unsupportedPanel: return "当前文件窗口没有可安全操作的“前往文件夹”入口。"
        case .timedOut: return "文件窗口未及时响应，已停止目录跳转。"
        case .cannotWritePath: return "无法向“前往文件夹”填写目录路径。"
        case .unverifiedDirectory: return "已执行目录跳转，但当前应用未提供足够信息确认目录位置。"
        }
    }
}

final class FinderJumpNavigationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

enum FinderJumpNavigation {
    private struct GoPanel {
        let sheet: AXUIElement
        let field: AXUIElement
        let nodes: [AXUIElement]
    }

    static func run(session: FinderJumpPanelSession, directory: URL, isCurrent: () -> Bool,
                    trace: ((String) -> Void)? = nil) throws {
        guard FinderJumpLocationCache.isRealDirectory(directory) else { throw FinderJumpNavigationError.missingDirectory }
        try validate(session, isCurrent: isCurrent)
        trace?("已核验文件面板")
        guard goPanel(in: session) == nil else { throw FinderJumpNavigationError.changedFocus }
        let nameField = session.nodes.first { FinderJumpAX.string($0, "AXIdentifier") == "saveAsNameTextField" }
        let originalName = nameField.map { FinderJumpAX.string($0, "AXValue") }
        // 折叠保存面板没有文件浏览区域，展开标准系统控件后才能读取实际目录。
        if let disclosure = session.nodes.first(where: { FinderJumpAX.string($0, "AXIdentifier") == "NS_OPEN_SAVE_DISCLOSURE_TRIANGLE" }),
           (FinderJumpAX.value(disclosure, "AXValue") as? NSNumber)?.intValue == 0 {
            try validate(session, isCurrent: isCurrent)
            let response = FinderJumpAX.perform("AXPress", on: disclosure)
            guard response == .success || response == .cannotComplete else { throw FinderJumpNavigationError.unsupportedPanel }
            trace?("已请求展开保存面板，等待浏览区域")
            _ = try wait(seconds: 2, session: session, isCurrent: isCurrent) { () -> Bool? in
                FinderJumpAX.walk(session.panel).contains { ["AXBrowser", "AXOutline", "AXTable"].contains(FinderJumpAX.string($0, "AXRole")) } ? true : nil
            }
        }
        // 仅此快捷键用于调起系统子面板；路径从不经过剪贴板。
        try post(key: 5, flags: [.maskCommand, .maskShift], session: session, isCurrent: isCurrent)
        let go = try wait(seconds: 2.5, session: session, isCurrent: isCurrent) { goPanel(in: session) }
        trace?("已打开前往文件夹")
        try validate(session, go: go, isCurrent: isCurrent)
        var writable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(go.field, "AXValue" as CFString, &writable) == .success, writable.boolValue,
              AXUIElementSetAttributeValue(go.field, "AXValue" as CFString, directory.path as CFString) == .success,
              FinderJumpAX.string(go.field, "AXValue") == directory.path else {
            throw FinderJumpNavigationError.cannotWritePath
        }
        trace?("路径已写入并回读一致")
        // 等系统接受新的完整路径再确认，避免沿用之前的建议列表。
        let ready = try wait(seconds: 2.5, session: session, isCurrent: isCurrent) { () -> GoPanel? in
            guard let current = goPanel(in: session), CFEqual(current.sheet, go.sheet),
                  FinderJumpAX.string(current.field, "AXValue") == directory.path else { return nil }
            let matchingSuggestion = current.nodes.contains {
                FinderJumpAX.string($0, "AXIdentifier") == directory.path
                    && FinderJumpAX.string($0, "AXRole") == "AXList"
            }
            let button = confirmationButton(in: current)
            return matchingSuggestion || button != nil ? current : nil
        }
        trace?("已出现完整路径建议")
        try validate(session, go: ready, isCurrent: isCurrent)
        guard FinderJumpLocationCache.isRealDirectory(directory) else { throw FinderJumpNavigationError.missingDirectory }
        if let button = confirmationButton(in: ready) {
            trace?("确认方式：子面板按钮")
            let response = FinderJumpAX.perform("AXPress", on: button)
            guard response == .success || response == .cannotComplete else { throw FinderJumpNavigationError.unsupportedPanel }
        } else {
            // macOS 26 的 GoToWindow 没有 Go 按钮。这里只在确切子面板、路径和焦点同时回读一致后，
            // 向当前已核验的系统面板发送一次 Return；不自动重试，也不向外层打开／保存按钮执行动作。
            try validate(session, go: ready, isCurrent: isCurrent)
            guard FinderJumpAX.string(ready.field, "AXValue") == directory.path else { throw FinderJumpNavigationError.changedFocus }
            trace?("确认方式：核验焦点后单次 Return")
            try post(key: 36, flags: [], session: session, go: ready, expectedPath: directory.path, isCurrent: isCurrent)
        }
        _ = try wait(seconds: 3, session: session, isCurrent: isCurrent) { () -> Bool? in
            guard goPanel(in: session) == nil else { return nil }
            return true
        }
        trace?("前往文件夹已关闭，外层面板仍存在")
        do {
            _ = try wait(seconds: 2, session: session, isCurrent: isCurrent) { () -> Bool? in
                directoryIsVisible(directory, session: session) ? true : nil
            }
        } catch FinderJumpNavigationError.timedOut {
            throw FinderJumpNavigationError.unverifiedDirectory
        }
        trace?("实际目录回读一致")
        if let originalName {
            let currentNameField = FinderJumpAX.walk(session.panel).first { FinderJumpAX.string($0, "AXIdentifier") == "saveAsNameTextField" }
            guard let currentNameField, FinderJumpAX.string(currentNameField, "AXValue") == originalName else {
                throw FinderJumpNavigationError.changedFocus
            }
        }
    }

    private static func validate(_ session: FinderJumpPanelSession, go: GoPanel? = nil, isCurrent: () -> Bool) throws {
        guard isCurrent(), AXIsProcessTrusted() else { throw FinderJumpNavigationError.changedFocus }
        // 系统创建远程 GoToWindow 时会短暂不给出前台/焦点属性；未知与已确认换窗必须分开。
        guard let frontmost = FinderJumpAX.value(session.application, "AXFrontmost") as? Bool else {
            throw FinderJumpNavigationError.accessibilityBusy
        }
        guard frontmost else { throw FinderJumpNavigationError.changedFocus }
        guard let currentWindow = FinderJumpAX.focusedWindow(session.application) else {
            throw FinderJumpNavigationError.accessibilityBusy
        }
        guard CFEqual(currentWindow, session.window),
              FinderJumpAX.walk(currentWindow).contains(where: { CFEqual($0, session.panel) }),
              ["open-panel", "save-panel"].contains(FinderJumpAX.string(session.panel, "AXIdentifier")) else {
            throw FinderJumpNavigationError.changedFocus
        }
        if let go {
            guard let current = goPanel(in: session), CFEqual(current.sheet, go.sheet), CFEqual(current.field, go.field),
                  FinderJumpAX.value(go.field, "AXFocused") as? Bool == true else {
                throw FinderJumpNavigationError.changedFocus
            }
        } else {
            let sheets = FinderJumpAX.walk(session.panel).filter {
                !CFEqual($0, session.panel) && FinderJumpAX.string($0, "AXRole") == "AXSheet"
            }
            guard sheets.allSatisfy({ FinderJumpAX.string($0, "AXIdentifier") == "GoToWindow" }) else {
                throw FinderJumpNavigationError.changedFocus
            }
        }
    }

    private static func goPanel(in session: FinderJumpPanelSession) -> GoPanel? {
        let nodes = FinderJumpAX.walk(session.panel)
        guard let sheet = nodes.first(where: {
            FinderJumpAX.string($0, "AXRole") == "AXSheet" && FinderJumpAX.string($0, "AXIdentifier") == "GoToWindow"
        }) else { return nil }
        let contents = FinderJumpAX.walk(sheet, includeRows: true, limit: 100, timeout: 0.5)
        let fields = contents.filter {
            FinderJumpAX.string($0, "AXRole") == "AXTextField" && FinderJumpAX.string($0, "AXIdentifier") == "PathTextField"
        }
        guard fields.count == 1 else { return nil }
        return .init(sheet: sheet, field: fields[0], nodes: contents)
    }

    private static func confirmationButton(in go: GoPanel) -> AXUIElement? {
        go.nodes.first {
            FinderJumpAX.string($0, "AXRole") == "AXButton"
                && ["GoButton", "goButton", "OKButton"].contains(FinderJumpAX.string($0, "AXIdentifier"))
                && FinderJumpAX.value($0, "AXEnabled") as? Bool == true
                && FinderJumpAX.actions($0).contains("AXPress")
        }
    }

    private static func wait<T>(seconds: TimeInterval, session: FinderJumpPanelSession, isCurrent: () -> Bool,
                                read: () -> T?) throws -> T {
        try waitForReadiness(seconds: seconds, validate: {
            try validate(session, isCurrent: isCurrent)
        }, read: read)
    }

    /// 只在过渡等待期间容忍暂不可读；真正发键和写值仍要求严格校验成功。
    static func waitForReadiness<T>(seconds: TimeInterval, validate: () throws -> Void, read: () -> T?) throws -> T {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            do {
                try validate()
                if let result = read() { return result }
            } catch FinderJumpNavigationError.accessibilityBusy {
                // 不重发上一条命令、不执行 read/write，保留原截止时间有界重读。
            }
            Thread.sleep(forTimeInterval: 0.06)
        } while Date() < deadline
        throw FinderJumpNavigationError.timedOut
    }

    private static func post(key: CGKeyCode, flags: CGEventFlags, session: FinderJumpPanelSession,
                             go: GoPanel? = nil, expectedPath: String? = nil, isCurrent: () -> Bool) throws {
        guard CGPreflightPostEventAccess(),
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            throw FinderJumpNavigationError.unsupportedPanel
        }
        try validate(session, go: go, isCurrent: isCurrent)
        if let go, let expectedPath, FinderJumpAX.string(go.field, "AXValue") != expectedPath {
            throw FinderJumpNavigationError.changedFocus
        }
        guard isCurrent() else { throw FinderJumpNavigationError.changedFocus }
        // postToPid 无法可靠穿过系统远程面板的键盘路由。交给当前登录会话的 key-window 路由，
        // 发出前重新检查前台应用、宿主窗口、确切面板和操作代次，且每步只发送一次。
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: 0x4152504A)
            event.post(tap: .cgSessionEventTap)
        }
    }

    /// 读取系统实际列出的文件 URL 来确认目录，而非把按键已发送或同名目录标题当成功。
    static func directoryIsVisible(_ expected: URL, session: FinderJumpPanelSession) -> Bool {
        let deadline = Date().addingTimeInterval(1.2)
        let canonical = expected.resolvingSymlinksInPath().standardizedFileURL
        for node in [session.panel, session.window] {
            for key in ["AXDocument", "AXURL"] {
                if fileURL(FinderJumpAX.value(node, key))?.resolvingSymlinksInPath().standardizedFileURL == canonical { return true }
            }
        }
        let controls = FinderJumpAX.walk(session.panel)
        guard let whereButton = controls.first(where: { FinderJumpAX.string($0, "AXIdentifier") == "where popup" }) else { return false }
        let localized = (try? expected.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
        let displayed = FinderJumpAX.string(whereButton, "AXValue")
        guard [expected.lastPathComponent, canonical.lastPathComponent, localized ?? ""].contains(displayed) else { return false }
        let browser = controls.first(where: { FinderJumpAX.string($0, "AXRole") == "AXBrowser" })
        let columns = browser.flatMap { FinderJumpAX.value($0, "AXColumns") as? [AXUIElement] } ?? []
        let root = columns.last ?? browser ?? session.panel
        let contents = FinderJumpAX.walk(root, includeRows: true, limit: 160, timeout: 0.6)
        for node in contents {
            guard Date() < deadline else { return false }
            guard let url = fileURL(FinderJumpAX.value(node, "AXURL"))?.resolvingSymlinksInPath().standardizedFileURL else { continue }
            if url.deletingLastPathComponent() == canonical { return true }
        }
        // 空文件夹的最后一列没有文件行，回读前一列真正选中的目录 URL。
        if columns.count > 1 {
            let previous = FinderJumpAX.walk(columns[columns.count - 2], includeRows: true, limit: 140, timeout: 0.5)
            for node in previous {
                guard Date() < deadline else { return false }
                let selected = FinderJumpAX.value(node, "AXSelectedChildren") as? [AXUIElement] ?? []
                for selection in selected {
                    let items = FinderJumpAX.walk(selection, includeRows: true, limit: 12)
                    if items.contains(where: { fileURL(FinderJumpAX.value($0, "AXURL"))?.resolvingSymlinksInPath().standardizedFileURL == canonical }) { return true }
                }
            }
        }
        return false
    }

    private static func fileURL(_ value: CFTypeRef?) -> URL? {
        if let url = value as? URL, url.isFileURL { return url }
        if let string = value as? String, let url = URL(string: string), url.isFileURL { return url }
        return nil
    }
}
