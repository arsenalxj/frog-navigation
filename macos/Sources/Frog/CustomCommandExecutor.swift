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

/// 后台程序的终止句柄；跨线程访问用锁保护，仅供明确确认后的停止操作使用。
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
        case .finder: identifier = "com.apple.finder"
        case .none: return nil
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func installedTerminals() -> [CustomCommandTerminal] {
        [.terminal, .iTerm2, .ghostty].filter { applicationURL(for: $0) != nil }
    }

    func execute(_ command: CustomCommand, input: String) async throws -> CustomCommandExecutionResult {
        // 启动前校验失败也要清除排队的停止请求，不能影响下一条命令。
        defer { runningProgram.attach(nil) }
        let command = try command.validated(reservedNames: [])
        if command.type == .url {
            let destination = try Self.url(template: command.target, input: input)
            guard NSWorkspace.shared.open(destination) else {
                throw CustomCommandExecutionError.invalid("无法打开网址，请检查默认浏览器")
            }
            return CustomCommandExecutionResult(summary: "已交由浏览器打开", output: destination.absoluteString, exitCode: nil)
        }

        let directory = try Self.directoryURL(command.directory)
        let arguments = try Self.arguments(template: command.arguments, input: input)
        if command.terminal == .finder {
            guard let finder = Self.applicationURL(for: .finder) else {
                throw CustomCommandExecutionError.invalid("未找到 Finder")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open([directory], withApplicationAt: finder, configuration: configuration) { application, error in
                    if let error { continuation.resume(throwing: error) }
                    else if application == nil { continuation.resume(throwing: CustomCommandExecutionError.invalid("无法启动 Finder")) }
                    else { continuation.resume() }
                }
            }
            return CustomCommandExecutionResult(summary: "已交由 Finder 打开", output: directory.path, exitCode: nil)
        }
        if command.type == .program && command.terminal == .none {
            let executable = try Self.executableURL(command.target)
            let cancellation = runningProgram
            return try await Task.detached(priority: .userInitiated) {
                try Self.runProcess(executable: executable, directory: directory, arguments: arguments,
                                    cancellation: cancellation)
            }.value
        }

        guard command.terminal != .none else {
            throw CustomCommandExecutionError.invalid("请选择可用的终端应用")
        }
        guard let application = Self.applicationURL(for: command.terminal) else {
            throw CustomCommandExecutionError.invalid("未找到 \(command.terminal.label)")
        }
        let script = try prepareTerminalScript(command, input: input)
        var fallbackNote = ""
        if command.terminal == .ghostty,
           !NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty")
               .filter({ !$0.isTerminated }).isEmpty {
            do {
                let target = try openGhosttyTab(script: script, directory: directory)
                return CustomCommandExecutionResult(summary: "已在 Ghostty \(target)中打开",
                                                    output: "", exitCode: nil)
            } catch {
                fallbackNote = "（\(error.localizedDescription)，已改用新窗口）"
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
                        continuation.resume(throwing: CustomCommandExecutionError.invalid("无法启动终端"))
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
            throw CustomCommandExecutionError.invalid("无法交由 \(command.terminal.label) 打开：\(error.localizedDescription)")
        }
        return CustomCommandExecutionResult(summary: "已交由 \(command.terminal.label) 打开\(fallbackNote)", output: "", exitCode: nil)
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
                message = "未授权自动化控制 Ghostty"
            case -1708, -2740, -2741:
                message = "Ghostty 未启用脚本支持（macos-applescript）"
            default:
                message = error[NSAppleScript.errorMessage] as? String ?? "脚本执行失败"
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
        guard command.type != .url, command.terminal != .none, command.terminal != .finder else {
            throw CustomCommandExecutionError.invalid("请选择使用终端的命令")
        }
        let directory = try Self.directoryURL(command.directory)
        let arguments = try Self.arguments(template: command.arguments, input: input)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("frog-command-\(UUID().uuidString)", isDirectory: true)
        let script = temporaryDirectory.appendingPathComponent("run.command")
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let content: String
            if command.type == .directory {
                content = try prepareDirectoryStartup(directory: directory, temporaryDirectory: temporaryDirectory)
            } else {
                let target = command.type == .program
                    ? Self.shellQuote(try Self.executableURL(command.target).path) : command.target
                // Startup files establish the login PATH; cd afterwards preserves the requested cwd.
                let body = "cd -- \(Self.shellQuote(directory.path)) || { printf '%s\\n' '无法进入工作目录，请检查目录是否存在及访问权限。' >&2; exit 1; }\n\(target) \"$@\""
                content = """
                #!/bin/sh
                /bin/rm -f -- \(Self.shellQuote(script.path))
                /bin/rmdir -- \(Self.shellQuote(temporaryDirectory.path))
                exec /bin/zsh -lic \(Self.shellQuote(body)) frog-custom-command\(arguments.map { " " + Self.shellQuote($0) }.joined())
                """ + "\n"
            }
            guard FileManager.default.createFile(atPath: script.path, contents: Data(content.utf8), attributes: [.posixPermissions: 0o700]) else {
                throw CustomCommandExecutionError.invalid("无法写入启动脚本")
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw CustomCommandExecutionError.invalid("无法准备终端脚本：\(error.localizedDescription)")
        }
        return script
    }

    private func prepareDirectoryStartup(directory: URL, temporaryDirectory: URL) throws -> String {
        let files = [".zshenv", ".zprofile", ".zshrc", ".zlogin"]
        let cleanup = files.map { Self.shellQuote(temporaryDirectory.appendingPathComponent($0).path) }.joined(separator: " ")
        let finish = """
        unset FROG_DIRECTORY_ZDOTDIR_SET FROG_DIRECTORY_ZDOTDIR
        /bin/rm -f -- \(cleanup)
        /bin/rmdir -- \(Self.shellQuote(temporaryDirectory.path))
        builtin cd -- \(Self.shellQuote(directory.path)) || { printf '%s\\n' '无法进入工作目录，请检查目录是否存在及访问权限。' >&2; exit 1; }
        """
        // Forward each startup phase in the same shell, then cd after the last user startup file.
        for file in files {
            let restoreAndSource = """
            if [[ $FROG_DIRECTORY_ZDOTDIR_SET == 1 ]]; then
                export ZDOTDIR="$FROG_DIRECTORY_ZDOTDIR"
            else
                unset ZDOTDIR
            fi
            [[ ! -r "${ZDOTDIR-$HOME}/\(file)" ]] || builtin source "${ZDOTDIR-$HOME}/\(file)"
            """
            let continuation = file == ".zlogin" ? finish : """
            if [[ ! -o rcs ]]\(file == ".zshrc" ? " || [[ ! -o login ]]" : ""); then
                \(finish)
            else
                FROG_DIRECTORY_ZDOTDIR_SET=${+ZDOTDIR}
                FROG_DIRECTORY_ZDOTDIR=${ZDOTDIR-}
                export ZDOTDIR=\(Self.shellQuote(temporaryDirectory.path))
            fi
            """
            let bytes = Data((restoreAndSource + "\n" + continuation + "\n").utf8)
            guard FileManager.default.createFile(atPath: temporaryDirectory.appendingPathComponent(file).path,
                                                 contents: bytes, attributes: [.posixPermissions: 0o600]) else {
                throw CustomCommandExecutionError.invalid("无法写入目录启动配置。")
            }
        }
        return """
        #!/bin/sh
        /bin/rm -f -- \(Self.shellQuote(temporaryDirectory.appendingPathComponent("run.command").path))
        if [ "${ZDOTDIR+x}" = x ]; then
            export FROG_DIRECTORY_ZDOTDIR_SET=1 FROG_DIRECTORY_ZDOTDIR="$ZDOTDIR"
        else
            export FROG_DIRECTORY_ZDOTDIR_SET=0 FROG_DIRECTORY_ZDOTDIR=''
        fi
        export ZDOTDIR=\(Self.shellQuote(temporaryDirectory.path))
        exec /bin/zsh -il
        """ + "\n"
    }

    nonisolated static func arguments(template: String, input: String) throws -> [String] {
        guard !template.contains("\0"), !input.contains("\0") else {
            throw CustomCommandExecutionError.invalid("参数不能包含空字符")
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
            throw CustomCommandExecutionError.invalid("参数模板中的引号或转义未闭合")
        }
        if started { words.append(word) }
        guard input.isEmpty || words.contains(where: { $0.contains("{args}") }) else {
            throw CustomCommandExecutionError.invalid("此命令不接收参数（模板缺少 {args}）")
        }
        // Substitute only after tokenization: runtime text is one literal argument, never shell syntax.
        return words.map { $0.replacingOccurrences(of: "{args}", with: input) }
    }

    nonisolated static func url(template: String, input: String) throws -> URL {
        let hasQuery = template.contains("{query}")
        guard !hasQuery || !input.isEmpty else {
            throw CustomCommandExecutionError.invalid("请在命令后输入查询内容")
        }
        guard hasQuery || input.isEmpty else {
            throw CustomCommandExecutionError.invalid("此网址不接收参数（模板缺少 {query}）")
        }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = input.addingPercentEncoding(withAllowedCharacters: unreserved),
              let destination = URL(string: template.replacingOccurrences(of: "{query}", with: encoded)),
              let scheme = destination.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = destination.host, !host.isEmpty else {
            throw CustomCommandExecutionError.invalid("网址须为有效的 http:// 或 https:// 地址")
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
            throw CustomCommandExecutionError.invalid("工作目录不存在或不是文件夹：\(path)")
        }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    nonisolated private static func executableURL(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard expanded.hasPrefix("/"), !expanded.contains("\0"),
              FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw CustomCommandExecutionError.invalid("找不到程序或脚本：\(path)")
        }
        guard FileManager.default.isExecutableFile(atPath: expanded) else {
            throw CustomCommandExecutionError.invalid("程序缺少执行权限：\(path)")
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
            throw CustomCommandExecutionError.invalid("无法启动程序：\(error.localizedDescription)")
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
            ? "已终止（信号 \(status)）"
            : "已退出（退出码 \(status)）"
        return CustomCommandExecutionResult(summary: summary, output: output, exitCode: status)
    }
}
