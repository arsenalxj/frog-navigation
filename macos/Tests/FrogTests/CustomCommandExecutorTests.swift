import Foundation
import FrogCore
import XCTest
@testable import Frog

final class CustomCommandExecutorTests: XCTestCase {
    func testQuotedArgumentWordsAndEmptyArguments() throws {
        XCTAssertEqual(
            try CustomCommandExecutor.arguments(template: #"one 'two three' "four five" six\ seven '' """#, input: ""),
            ["one", "two three", "four five", "six seven", "", ""]
        )
        XCTAssertEqual(
            try CustomCommandExecutor.arguments(template: #""a\qb" "a\"b" '$HOME' `literal`"#, input: ""),
            [#"a\qb"#, "a\"b", "$HOME", "`literal`"]
        )
        XCTAssertEqual(try CustomCommandExecutor.arguments(template: "one\\\ntwo", input: ""), ["onetwo"])
    }

    func testRuntimeArgumentsAreSubstitutedAfterParsingOnly() throws {
        let input = "two words ' \"; $(touch forbidden); `whoami`\\\n{args}"
        XCTAssertEqual(
            try CustomCommandExecutor.arguments(template: #"--query={args} '{args}' fixed"#, input: input),
            ["--query=" + input, input, "fixed"]
        )
        XCTAssertEqual(try CustomCommandExecutor.arguments(template: "{args}", input: ""), [""])
    }

    func testUnexpectedInputAndMalformedTemplatesAreRejected() {
        for template in ["'unfinished", "\"unfinished", "trailing\\"] {
            XCTAssertThrowsError(try CustomCommandExecutor.arguments(template: template, input: ""))
        }
        XCTAssertThrowsError(try CustomCommandExecutor.arguments(template: "--fixed", input: "extra"))
        XCTAssertThrowsError(try CustomCommandExecutor.arguments(template: "{args}", input: "a\0b"))
        XCTAssertThrowsError(try CustomCommandExecutor.arguments(template: "a\0b", input: ""))
    }

    func testURLQueryUsesOnlyRFC3986UnreservedCharacters() throws {
        let url = try CustomCommandExecutor.url(template: "https://example.com/search?q={query}&copy={query}", input: "青蛙 a+b&x=#/?%~-._")
        let encoded = "%E9%9D%92%E8%9B%99%20a%2Bb%26x%3D%23%2F%3F%25~-._"
        XCTAssertEqual(url.absoluteString, "https://example.com/search?q=\(encoded)&copy=\(encoded)")
    }

    func testURLRejectsMissingQueryUnexpectedInputAndUnsupportedSchemes() throws {
        XCTAssertThrowsError(try CustomCommandExecutor.url(template: "https://example.com/?q={query}", input: ""))
        XCTAssertThrowsError(try CustomCommandExecutor.url(template: "https://example.com/", input: "extra"))
        XCTAssertThrowsError(try CustomCommandExecutor.url(template: "file:///tmp/example", input: ""))
        XCTAssertThrowsError(try CustomCommandExecutor.url(template: "https:///", input: ""))
        XCTAssertEqual(try CustomCommandExecutor.url(template: "https://example.com/", input: "").absoluteString, "https://example.com/")
    }

    @MainActor
    func testProgramReturnsRealExitCodeCwdStdoutStderrAndLiteralInput() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(in: directory, content: """
        #!/bin/sh
        /bin/pwd
        printf 'stdout:%s\\n' "$1"
        printf 'stderr:observed\\n' >&2
        exit 7
        """)
        let input = "a'; $(touch forbidden); `touch forbidden`; \" two words\nnext"
        let command = CustomCommand(name: "fixture", title: "隔离进程", type: .program, directory: directory.path, target: executable.path, arguments: "{args}", terminal: .none)
        let result = try await CustomCommandExecutor().execute(command, input: input)
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertTrue(result.summary.contains("7"))
        XCTAssertTrue(result.output.contains(directory.resolvingSymlinksInPath().path))
        XCTAssertTrue(result.output.contains("stdout:\(input)\n"))
        XCTAssertTrue(result.output.contains("stderr:observed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("forbidden").path))
    }

    @MainActor
    func testBothOutputStreamsAreDrainedAfterCaptureLimit() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(in: directory, content: """
        #!/bin/sh
        i=0
        while [ "$i" -lt 14000 ]; do
            printf 'stdout-0123456789\\n'
            printf 'stderr-0123456789\\n' >&2
            i=$((i + 1))
        done
        exit 23
        """)
        let command = CustomCommand(name: "flood", title: "隔离输出", type: .program, directory: directory.path, target: executable.path, terminal: .none)
        let result = try await CustomCommandExecutor().execute(command, input: "")
        XCTAssertEqual(result.exitCode, 23)
        XCTAssertTrue(result.output.contains("输出已截断"))
        XCTAssertLessThan(result.output.utf8.count, CustomCommandExecutor.outputLimit + 200)
        XCTAssertTrue(result.output.contains("stdout-"))
        XCTAssertTrue(result.output.contains("stderr-"))
    }

    @MainActor
    func testShellQuotingPreservesDataWhenActuallyExecuted() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = "'\"; $(touch forbidden)\n* $HOME \\ end"
        let shellCode = "printf '%s' " + CustomCommandExecutor.shellQuote(input)
        let template = ["-c", shellCode].map(CustomCommandExecutor.shellQuote).joined(separator: " ")
        let command = CustomCommand(name: "quote", title: "隔离引用", type: .program, directory: directory.path, target: "/bin/sh", arguments: template, terminal: .none)
        let result = try await CustomCommandExecutor().execute(command, input: "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, input)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("forbidden").path))
    }

    @MainActor
    func testProgramReportsMissingDirectoryProgramAndExecutePermission() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nonExecutable = directory.appendingPathComponent("plain-file")
        try Data("plain".utf8).write(to: nonExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nonExecutable.path)
        let cases = [
            (directory.appendingPathComponent("absent").path, "/bin/echo", "工作目录"),
            (directory.path, directory.appendingPathComponent("absent").path, "找不到程序"),
            (directory.path, nonExecutable.path, "执行权限"),
            (directory.path, directory.path, "找不到程序")
        ]
        for (cwd, target, message) in cases {
            let command = CustomCommand(name: "invalid", title: "无效配置", type: .program, directory: cwd, target: target, terminal: .none)
            do {
                _ = try await CustomCommandExecutor().execute(command, input: "")
                XCTFail("Expected a launch error for \(target)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(message), error.localizedDescription)
            }
        }
    }

    @MainActor
    func testTerminalPreparationIsPrivateUniqueAndDefersCleanupToConsumption() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = CustomCommand(name: "terminal", title: "终端准备", directory: directory.path, target: "printf '%s\\n'", arguments: "{args}")
        let executor = CustomCommandExecutor()
        let input = "'; touch forbidden; #"
        let first = try executor.prepareTerminalScript(command, input: input)
        defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
        let second = try executor.prepareTerminalScript(command, input: input)
        defer { try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }
        XCTAssertNotEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent())
        XCTAssertEqual(first.pathExtension, "command")
        for url in [first, first.deletingLastPathComponent()] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    @MainActor
    func testPreparedGhosttyScriptExecutesLiteralArgumentsAndCleansUp() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(in: directory, content: "#!/bin/sh\nprintf '%s' \"$1\" > argument.txt\npwd > cwd.txt\n")
        var command = CustomCommand(name: "program", title: "程序启动", type: .program, directory: directory.path,
                                    target: executable.path, arguments: "{args}", terminal: .ghostty)
        let input = "中文 ' ; $(touch forbidden) & \""
        let script = try CustomCommandExecutor().prepareTerminalScript(command, input: input)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let process = Process()
        process.executableURL = script
        process.environment = ["HOME": directory.path, "ZDOTDIR": directory.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "dumb"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("argument.txt"), encoding: .utf8), input)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("cwd.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), directory.resolvingSymlinksInPath().path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.deletingLastPathComponent().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("forbidden").path))
        command.target = directory.appendingPathComponent("absent").path
        XCTAssertThrowsError(try CustomCommandExecutor().prepareTerminalScript(command, input: ""))
    }

    func testAppleScriptLiteralEscapesQuotesAndBackslashes() {
        XCTAssertEqual(CustomCommandExecutor.appleScriptString("a\"b\\c"), "\"a\\\"b\\\\c\"")
        XCTAssertEqual(CustomCommandExecutor.appleScriptString("/tmp/项目 空格/run.command"), "\"/tmp/项目 空格/run.command\"")
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("frog-executor-tests-\(UUID().uuidString)-' spaced", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func makeExecutable(in directory: URL, content: String) throws -> URL {
        let executable = directory.appendingPathComponent("fixture ' executable.sh")
        try Data(content.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
}
