import AppKit
import FrogCore

struct CustomCommandExecutionResult: Sendable {
    let summary: String
    let output: String
    let exitCode: Int32?
}

private enum CustomCommandExecutionError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

/// 后台程序的终止句柄；跨线程访问用锁保护，供 Esc 终止使用。
final class RunningProgramBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelRequested = false

    func attach(_ newProcess: Process?) {
        lock.lock()
        process = newProcess
        let shouldCancel = newProcess != nil && cancelRequested
        if newProcess == nil || shouldCancel { cancelRequested = false }
        lock.unlock()
        if shouldCancel { newProcess?.terminate() }
    }

    func terminate() {
        lock.lock()
        let current = process
        if current == nil { cancelRequested = true }
        lock.unlock()
        current?.terminate()
    }
}

@MainActor
final class CustomCommandExecutor {
    nonisolated static let outputLimit = 65_536
    private let runningProgram = RunningProgramBox()

    func cancelRunningProgram() {
        runningProgram.terminate()
    }

    static func applicationURL(for terminal: CustomCommandTerminal) -> URL? {
        let identifier: String
        switch terminal {
        case .terminal: identifier = "com.apple.Terminal"
        case .iTerm2: identifier = "com.googlecode.iterm2"
        case .ghostty: identifier = "com.mitchellh.ghostty"
        case .none: return nil
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func installedTerminals() -> [CustomCommandTerminal] {
        CustomCommandTerminal.allCases.filter { applicationURL(for: $0) != nil }
    }

    func execute(_ command: CustomCommand, input: String) async throws -> CustomCommandExecutionResult {
        let command = try command.validated(reservedNames: [])
        if command.type == .url {
            let destination = try Self.url(template: command.target, input: input)
            guard NSWorkspace.shared.open(destination) else {
                throw CustomCommandExecutionError.invalid("无法打开网址，请检查默认浏览器设置。")
            }
            return CustomCommandExecutionResult(summary: "已交给默认浏览器；未确认网页加载结果。", output: destination.absoluteString, exitCode: nil)
        }

        let directory = try Self.directoryURL(command.directory)
        let arguments = try Self.arguments(template: command.arguments, input: input)
        if command.type == .program && command.terminal == .none {
            let executable = try Self.executableURL(command.target)
            let cancellation = runningProgram
            return try await Task.detached(priority: .userInitiated) {
                try Self.runProcess(executable: executable, directory: directory, arguments: arguments,
                                    cancellation: cancellation)
            }.value
        }

        guard command.terminal != .none else {
            throw CustomCommandExecutionError.invalid("终端命令必须选择可用的终端应用。")
        }
        guard let application = Self.applicationURL(for: command.terminal) else {
            throw CustomCommandExecutionError.invalid("未找到 \(command.terminal.label)，请先安装或改选其他终端。")
        }
        let script = try prepareTerminalScript(command, input: input)
        var fallbackNote = ""
        if command.terminal == .ghostty,
           !NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty")
               .filter({ !$0.isTerminated }).isEmpty {
            do {
                let target = try openGhosttyTab(script: script, directory: directory)
                return CustomCommandExecutionResult(summary: "已在 Ghostty 现有\(target)中打开；实际执行结果请查看终端。",
                                                    output: "", exitCode: nil)
            } catch {
                fallbackNote = "；控制 Ghostty 失败，已改为新窗口（\(error.localizedDescription)）"
            }
        }
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { application, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if application == nil {
                        continuation.resume(throwing: CustomCommandExecutionError.invalid("终端未返回已启动的应用。"))
                    } else {
                        continuation.resume()
                    }
                }
                if command.terminal == .ghostty {
                    // macOS Ghostty 要求通过 Launch Services 启动新实例，已有实例不会接收启动参数。
                    configuration.createsNewApplicationInstance = true
                    // 此实例只运行当前命令，不恢复或保存用户其他窗口的会话状态。
                    configuration.arguments = ["--window-save-state=never", "--working-directory=\(directory.path)", "-e", script.path]
                    NSWorkspace.shared.openApplication(at: application, configuration: configuration, completionHandler: completion)
                } else {
                    NSWorkspace.shared.open([script], withApplicationAt: application, configuration: configuration, completionHandler: completion)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
            throw CustomCommandExecutionError.invalid("无法将命令交给 \(command.terminal.label)：\(error.localizedDescription) 请检查终端安装与启动权限。")
        }
        return CustomCommandExecutionResult(summary: "已交给 \(command.terminal.label)\(fallbackNote)；实际执行结果请查看终端。", output: "", exitCode: nil)
    }

    /// 通过 Ghostty 脚本接口在现有窗口新建标签页；失败时由调用方回退到新实例。
    private func openGhosttyTab(script: URL, directory: URL) throws -> String {
        let source = """
        tell application "Ghostty"
            set cfg to new surface configuration
            set initial working directory of cfg to \(Self.appleScriptString(directory.path))
            set command of cfg to \(Self.appleScriptString(Self.shellQuote(script.path)))
            set wait after command of cfg to true
            if (count of windows) is 0 then
                new window with configuration cfg
                return "窗口"
            else
                new tab in front window with configuration cfg
                return "标签页"
            end if
        end tell
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message: String
            switch number {
            case -1743:
                message = "未授权控制 Ghostty；可在系统设置 › 隐私与安全性 › 自动化中允许"
            case -1708, -2740, -2741:
                message = "Ghostty 未启用脚本支持（macos-applescript）"
            default:
                message = error[NSAppleScript.errorMessage] as? String ?? "未知脚本错误"
            }
            throw CustomCommandExecutionError.invalid(message)
        }
        return result?.stringValue ?? "标签页"
    }

    nonisolated static func appleScriptString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // The receiver owns the file after dispatch; removing it sooner races Launch Services.
    func prepareTerminalScript(_ command: CustomCommand, input: String) throws -> URL {
        let command = try command.validated(reservedNames: [])
        guard command.type != .url, command.terminal != .none else {
            throw CustomCommandExecutionError.invalid("请选择使用终端应用的命令。")
        }
        let directory = try Self.directoryURL(command.directory)
        let arguments = try Self.arguments(template: command.arguments, input: input)
        let target = command.type == .program
            ? Self.shellQuote(try Self.executableURL(command.target).path)
            : command.target
        guard !target.contains("\0") else {
            throw CustomCommandExecutionError.invalid("执行内容不能包含空字符。")
        }
        // Startup files establish the login PATH; cd afterwards preserves the requested cwd.
        let body = "cd -- \(Self.shellQuote(directory.path)) || { printf '%s\\n' '无法进入工作目录，请检查目录是否存在及访问权限。' >&2; exit 1; }\n\(target) \"$@\""
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("frog-command-\(UUID().uuidString)", isDirectory: true)
        let script = temporaryDirectory.appendingPathComponent("run.command")
        let content = """
        #!/bin/sh
        /bin/rm -f -- \(Self.shellQuote(script.path))
        /bin/rmdir -- \(Self.shellQuote(temporaryDirectory.path))
        exec /bin/zsh -lic \(Self.shellQuote(body)) frog-custom-command\(arguments.map { " " + Self.shellQuote($0) }.joined())
        """ + "\n"
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: script.path, contents: Data(content.utf8), attributes: [.posixPermissions: 0o700]) else {
                throw CustomCommandExecutionError.invalid("无法写入终端启动脚本。")
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw CustomCommandExecutionError.invalid("无法准备终端命令：\(error.localizedDescription) 请检查临时目录权限与磁盘空间。")
        }
        return script
    }

    nonisolated static func arguments(template: String, input: String) throws -> [String] {
        guard !template.contains("\0"), !input.contains("\0") else {
            throw CustomCommandExecutionError.invalid("参数不能包含空字符。")
        }
        var words: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        var started = false
        for character in template {
            if escaped {
                escaped = false
                if character == "\n" { continue }
                if quote == "\"", character != "\"", character != "\\", character != "$", character != "`" {
                    word.append("\\")
                }
                word.append(character)
                started = true
            } else if character == "\\", quote != "'" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil } else { word.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started {
                    words.append(word)
                    word = ""
                    started = false
                }
            } else {
                word.append(character)
                started = true
            }
        }
        guard quote == nil, !escaped else {
            throw CustomCommandExecutionError.invalid("参数模板的引号或反斜杠未闭合，请检查单引号、双引号与转义。")
        }
        if started { words.append(word) }
        guard input.isEmpty || words.contains(where: { $0.contains("{args}") }) else {
            throw CustomCommandExecutionError.invalid("此命令不接收输入；请在参数模板中添加 {args}，或移除命令后的输入。")
        }
        // Substitute only after tokenization: runtime text is one literal argument, never shell syntax.
        return words.map { $0.replacingOccurrences(of: "{args}", with: input) }
    }

    nonisolated static func url(template: String, input: String) throws -> URL {
        let hasQuery = template.contains("{query}")
        guard !hasQuery || !input.isEmpty else {
            throw CustomCommandExecutionError.invalid("此网址需要查询内容，请在命令后输入搜索词。")
        }
        guard hasQuery || input.isEmpty else {
            throw CustomCommandExecutionError.invalid("此网址不接收输入；请在网址模板中添加 {query}，或移除命令后的输入。")
        }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = input.addingPercentEncoding(withAllowedCharacters: unreserved),
              let destination = URL(string: template.replacingOccurrences(of: "{query}", with: encoded)),
              let scheme = destination.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = destination.host, !host.isEmpty else {
            throw CustomCommandExecutionError.invalid("网址必须是有效的 http:// 或 https:// 地址，请检查网址模板。")
        }
        return destination
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    nonisolated private static func directoryURL(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard expanded.hasPrefix("/"), !expanded.contains("\0"),
              FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CustomCommandExecutionError.invalid("工作目录不存在或不是文件夹：\(path)。请在编辑命令中选择有效目录。")
        }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    nonisolated private static func executableURL(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard expanded.hasPrefix("/"), !expanded.contains("\0"),
              FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw CustomCommandExecutionError.invalid("找不到程序或脚本：\(path)。请填写可执行文件的绝对路径。")
        }
        guard FileManager.default.isExecutableFile(atPath: expanded) else {
            throw CustomCommandExecutionError.invalid("程序或脚本没有执行权限：\(path)。请先为该文件设置执行权限。")
        }
        return URL(fileURLWithPath: expanded)
    }

    nonisolated private static func runProcess(executable: URL, directory: URL, arguments: [String],
                                               cancellation: RunningProgramBox) throws -> CustomCommandExecutionResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        defer {
            cancellation.attach(nil)
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        do {
            try process.run()
        } catch {
            throw CustomCommandExecutionError.invalid("无法启动程序 \(executable.path)：\(error.localizedDescription) 请检查文件格式、执行权限和工作目录访问权限。")
        }
        cancellation.attach(process)
        try? pipe.fileHandleForWriting.close()
        var captured = Data()
        var truncated = false
        do {
            while let data = try pipe.fileHandleForReading.read(upToCount: 16_384), !data.isEmpty {
                let remaining = outputLimit - captured.count
                captured.append(contentsOf: data.prefix(remaining))
                if data.count > remaining { truncated = true }
            }
        } catch {
            process.terminate()
            process.waitUntilExit()
            throw CustomCommandExecutionError.invalid("读取程序输出失败：\(error.localizedDescription)")
        }
        process.waitUntilExit()
        let status = process.terminationStatus
        let output = String(decoding: captured, as: UTF8.self) + (truncated ? "\n[输出已截断，仅保留前 \(outputLimit) 字节]" : "")
        let summary = process.terminationReason == .uncaughtSignal
            ? "程序被信号终止：\(status)。"
            : "程序已退出，退出码：\(status)。"
        return CustomCommandExecutionResult(summary: summary, output: output, exitCode: status)
    }
}
